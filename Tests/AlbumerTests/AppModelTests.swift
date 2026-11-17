import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

private actor LibraryService: SpotifyService {
    var albums: [Album]
    var failure: SpotifyError?
    var requestCount = 0
    let delay: Duration
    let pageSize: Int

    init(_ albums: [Album], delay: Duration = .zero, pageSize: Int = 50) {
        self.albums = albums; self.delay = delay; self.pageSize = pageSize
    }
    func update(_ albums: [Album], failure: SpotifyError? = nil) {
        self.albums = albums; self.failure = failure
    }
    func savedAlbums(offset: Int) async throws -> AlbumPage {
        requestCount += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return AlbumPage(albums: Array(albums.dropFirst(offset).prefix(pageSize)), nextOffset: offset + pageSize < albums.count ? offset + pageSize : nil, total: albums.count)
    }
    func searchAlbums(query: String, offset: Int) async throws -> AlbumPage { try await savedAlbums(offset: offset) }
    func isSaved(_ album: AlbumID) async throws -> Bool { albums.contains { $0.albumID == album } }
    func setSaved(_ album: AlbumID, saved: Bool) async throws {}
    func playback() async throws -> PlaybackSnapshot? { nil }
    func devices() async throws -> [PlaybackDevice] { [] }
    func transfer(to device: String, play: Bool) async throws {}
    func playAlbum(_ album: AlbumID, device: String) async throws {}
    func command(_ command: PlayerCommand, device: String?) async throws {}
}

@MainActor
final class AppModelTests: XCTestCase {
    private func album(_ name: String) -> Album {
        Album(id: name, name: name, artists: [Artist(name: "Artist")], albumType: "album", images: [], releaseDate: "2020", totalTracks: 10)
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Model did not reach the expected state")
    }
    func testSuccessfulAuthorizationEndsBeforeSheetDismissalAndLibraryLoad() async throws {
        let service = LibraryService([album("Lonerism")], delay: .milliseconds(100))
        let model = AppModel(service: service)
        model.setForeground(false)
        model.isAuthorizing = true; model.showSettings = true
        let task = Task { await model.finishConnection() }
        try await waitUntil { await service.requestCount == 1 }
        XCTAssertTrue(model.isLoading)
        XCTAssertFalse(model.isAuthorizing, "Sheet disappearance must not treat library loading as unfinished authorization")
        XCTAssertFalse(model.showSettings)
        await task.value
        XCTAssertTrue(model.hasLoadedPage)
        XCTAssertEqual(model.albums.map(\.name), ["Lonerism"])
    }
    func testFailedInitialSyncIsNotAnEmptyLibraryAndCanRetry() async {
        let service = LibraryService([])
        await service.update([], failure: .http(503, "暂时不可用"))
        let model = AppModel(service: service)
        model.setForeground(false)
        await model.finishConnection()
        XCTAssertFalse(model.hasLoadedPage)
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.notice)

        await service.update([album("The Bends")])
        await model.retry()
        XCTAssertTrue(model.hasLoadedPage)
        XCTAssertEqual(model.albums.map(\.name), ["The Bends"])
        XCTAssertNil(model.notice)
    }
    func testReturningToCollectionKeepsWarmCacheAndManualRefreshSyncs() async throws {
        let service = LibraryService([album("Old")])
        let model = AppModel(service: service)
        model.setForeground(false)
        await model.finishConnection()
        await service.update([album("New")])
        model.showCollection()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.albums.map(\.name), ["Old"])
        let requests = await service.requestCount
        XCTAssertEqual(requests, 1)
        await model.refreshCollection()
        XCTAssertEqual(model.savedIDs, ["New"])
        XCTAssertEqual(model.checkedSavedIDs, ["New"])
    }
    func testReturningFromSpotifyDoesNotRefetchFreshLibrary() async throws {
        let service = LibraryService([album("Old")])
        let model = AppModel(service: service)
        model.setForeground(false)
        await model.finishConnection()
        await service.update([album("New")])
        model.setForeground(true)
        try await Task.sleep(for: .milliseconds(30))
        model.setForeground(false)
        XCTAssertEqual(model.albums.map(\.name), ["Old"])
        let requests = await service.requestCount
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.hasLoadedPage)
    }

    func testInfiniteScrollAppendsOnceAndRefreshPreservesLoadedExtent() async {
        let service = LibraryService([album("A"), album("B"), album("C"), album("D")], delay: .milliseconds(20), pageSize: 2)
        let model = AppModel(service: service)
        model.setForeground(false)
        await model.finishConnection()
        XCTAssertEqual(model.albums.map(\.id), ["A", "B"])
        async let first: Void = model.loadMoreAlbums()
        async let duplicate: Void = model.loadMoreAlbums()
        _ = await (first, duplicate)
        XCTAssertEqual(model.albums.map(\.id), ["A", "B", "C", "D"])
        XCTAssertNil(model.nextOffset)
        let requests = await service.requestCount
        XCTAssertEqual(requests, 2)
        await service.update([album("New"), album("A"), album("C"), album("D")])
        await model.refreshCollection()
        XCTAssertEqual(model.albums.map(\.id), ["New", "A", "C", "D"])
    }

    func testOfflineRestartRestoresAccountCacheWithoutShowingEmptyLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(cacheRoot: root, dataRoot: root.appendingPathComponent("data"))
        await store.saveLibrary(CachedLibrary(albums: [album("Cached")], nextOffset: 20, updatedAt: .distantPast), account: "one")
        let service = LibraryService([])
        await service.update([], failure: .http(503, "Offline"))
        let model = AppModel(service: service, localStore: store, cacheAccount: "one")
        model.setForeground(false)
        await model.finishConnection()
        XCTAssertEqual(model.albums.map(\.name), ["Cached"])
        XCTAssertEqual(model.nextOffset, 20)
        XCTAssertTrue(model.hasLoadedPage)
        let other = AppModel(service: service, localStore: store, cacheAccount: "two")
        other.setForeground(false)
        await other.finishConnection()
        XCTAssertTrue(other.albums.isEmpty)
        XCTAssertFalse(other.hasLoadedPage)
    }

    func testArrangementLoadsEntireCollectionWithoutChangingLibraryOrder() async {
        let service = LibraryService([album("A"), album("B"), album("C"), album("D"), album("E")], pageSize: 2)
        let model = AppModel(service: service)
        model.setForeground(false)
        await model.finishConnection()
        XCTAssertEqual(model.albums.map(\.id), ["A", "B"])
        await model.loadRemainingCollection()
        XCTAssertEqual(model.albums.map(\.id), ["A", "B", "C", "D", "E"])
        XCTAssertNil(model.nextOffset)
        await model.loadRemainingCollection()
        let requests = await service.requestCount
        XCTAssertEqual(requests, 3)
    }

    func testYearOrderingKeepsUnknownYearsLastAndTiesStable() {
        func record(_ id: String, _ date: String) -> Album {
            Album(id: id, name: id, artists: [], albumType: "album", images: [], releaseDate: date, totalTracks: 10)
        }
        let albums = [record("first", "2007-10-10"), record("unknown", ""), record("old", "1973"), record("second", "2007"), record("new", "2024-05")]
        XCTAssertEqual(AlbumSortOrder.oldestFirst.arrange(albums).map(\.id), ["old", "first", "second", "new", "unknown"])
        XCTAssertEqual(AlbumSortOrder.newestFirst.arrange(albums).map(\.id), ["new", "first", "second", "old", "unknown"])
        XCTAssertEqual(AlbumSortOrder.library.arrange(albums).map(\.id), albums.map(\.id))
        XCTAssertNil(record("invalid", "0000").releaseYear)
    }

    func testArtistGroupingCombinesPrimaryArtistAndOrdersAlbumsByYear() {
        func record(_ id: String, _ artist: String, _ year: String) -> Album {
            Album(id: id, name: id, artists: [Artist(name: artist), Artist(name: "Guest")], albumType: "album", images: [], releaseDate: year, totalTracks: 10)
        }
        let albums = [record("rainbows", "Radiohead", "2007"), record("ram", "Daft Punk", "2013"), record("bends", "radiohead", "1995")]
        let groups = AlbumArtistGroup.make(from: albums, grouped: true, order: .oldestFirst)
        XCTAssertEqual(groups.map(\.id), ["daft punk", "radiohead"])
        XCTAssertEqual(groups.last?.albums.map(\.id), ["bends", "rainbows"])
        XCTAssertEqual(groups.flatMap(\.albums).count, albums.count)
        let ungrouped = AlbumArtistGroup.make(from: albums, grouped: false, order: .newestFirst)
        XCTAssertEqual(ungrouped.count, 1)
        XCTAssertNil(ungrouped.first?.name)
        XCTAssertEqual(ungrouped.first?.albums.map(\.id), ["ram", "rainbows", "bends"])
    }
}
