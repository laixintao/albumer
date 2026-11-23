import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

private actor ArtistService: SpotifyService {
    var pages: [Int: AlbumPage]
    var saved: Set<String>
    var offsets: [Int] = []
    var failCheck = false
    var holdCheck = false
    var pendingCheck: CheckedContinuation<[Bool], Never>?
    var pendingFlags: [Bool] = []
    var playCount = 0

    init(pages: [Int: AlbumPage], saved: Set<String> = []) { self.pages = pages; self.saved = saved }
    func setFailure(_ fail: Bool) { failCheck = fail }
    func holdNextCheck() { holdCheck = true }
    func hasPendingCheck() -> Bool { pendingCheck != nil }
    func releaseCheck() { pendingCheck?.resume(returning: pendingFlags); pendingCheck = nil }
    func artistAlbums(_ id: String, offset: Int) async throws -> AlbumPage {
        offsets.append(offset)
        guard let page = pages[offset] else { throw SpotifyError.invalidResponse }
        return page
    }
    func savedAlbums(_ albums: [AlbumID]) async throws -> [Bool] {
        if failCheck { throw SpotifyError.restricted }
        let flags = albums.map { saved.contains($0.rawValue) }
        if holdCheck {
            holdCheck = false; pendingFlags = flags
            return await withCheckedContinuation { pendingCheck = $0 }
        }
        return flags
    }
    func savedAlbums(offset: Int) async throws -> AlbumPage {
        var ids = Set<String>()
        let albums = pages.keys.sorted().flatMap { pages[$0]!.albums }.filter { saved.contains($0.id) && ids.insert($0.id).inserted }
        return AlbumPage(albums: albums, nextOffset: nil, total: albums.count)
    }
    func searchAlbums(query: String, offset: Int) async throws -> AlbumPage { try await savedAlbums(offset: offset) }
    func isSaved(_ album: AlbumID) async throws -> Bool { saved.contains(album.rawValue) }
    func setSaved(_ album: AlbumID, saved: Bool) async throws {
        if saved { self.saved.insert(album.rawValue) } else { self.saved.remove(album.rawValue) }
    }
    func playback() async throws -> PlaybackSnapshot? { nil }
    func devices() async throws -> [PlaybackDevice] { [] }
    func transfer(to device: String, play: Bool) async throws { playCount += 1 }
    func playAlbum(_ album: AlbumID, device: String) async throws { playCount += 1 }
    func command(_ command: PlayerCommand, device: String?) async throws { playCount += 1 }
}

@MainActor
final class ArtistCatalogTests: XCTestCase {
    private let artist = Artist(name: "Artist", id: "artist1")
    private func album(_ id: String, year: String = "2020") -> Album {
        Album(id: id, name: id, artists: [artist], albumType: "album", images: [], releaseDate: year, totalTracks: 10)
    }
    private func service() -> ArtistService {
        ArtistService(pages: [0: AlbumPage(albums: [album("saved"), album("other", year: "2024")], nextOffset: 10, total: 3),
                              10: AlbumPage(albums: [album("other", year: "2024"), album("older", year: "1999")], nextOffset: nil, total: 3)],
                      saved: ["saved"])
    }
    private func waitForCheck(_ service: ArtistService) async throws {
        for _ in 0..<100 {
            if await service.hasPendingCheck() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("No pending saved check")
    }

    func testBackNavigationRestoresArtistAlbumAndOriginalSearchWithoutPlayback() async throws {
        let service = service()
        let model = AppModel(service: service)
        model.connection = .connected
        model.isSearching = true; model.query = "Artist"; model.searchOffset = 450; model.collectionOffset = 210
        model.albums = [album("original")]
        model.select(album("original"))
        XCTAssertTrue(model.returnsToAlbumGrid)
        model.openArtist(artist)
        let catalog = try XCTUnwrap(model.selectedArtist)
        catalog.scrollOffset = 320
        await model.loadArtistCatalog(catalog)
        model.select(album("other"))
        XCTAssertTrue(model.returnsToAlbumGrid)
        XCTAssertEqual(model.backLabel, "返回 Artist")
        let request = model.backRequest
        model.requestBack()
        XCTAssertNotEqual(model.backRequest, request)
        XCTAssertEqual(model.selectedAlbum?.id, "other", "The view must capture artwork before committing the return")
        model.goBack()
        XCTAssertTrue(model.selectedArtist === catalog)
        XCTAssertEqual(catalog.scrollOffset, 320)
        model.goBack()
        XCTAssertEqual(model.selectedAlbum?.id, "original")
        model.goBack()
        XCTAssertNil(model.selectedAlbum); XCTAssertNil(model.selectedArtist)
        XCTAssertTrue(model.navigationHistory.isEmpty)
        XCTAssertTrue(model.isSearching); XCTAssertEqual(model.query, "Artist")
        XCTAssertEqual(model.searchOffset, 450); XCTAssertEqual(model.collectionOffset, 210)
        XCTAssertEqual(model.albums.map(\.id), ["original"])
        let commands = await service.playCount
        XCTAssertEqual(commands, 0)
    }

    func testCatalogLoadsAllPagesDeduplicatesAndClassifiesBeforePublishing() async throws {
        let service = service()
        let model = AppModel(service: service)
        model.openArtist(artist)
        let catalog = try XCTUnwrap(model.selectedArtist)
        await model.loadArtistCatalog(catalog)
        XCTAssertEqual(catalog.albums(saved: true).map(\.id), ["saved"])
        XCTAssertEqual(catalog.albums(saved: false).map(\.id), ["other", "older"])
        XCTAssertNil(catalog.nextOffset); XCTAssertNil(catalog.error)
        XCTAssertFalse(catalog.isLoading)
        await model.loadArtistCatalog(catalog)
        let offsets = await service.offsets
        XCTAssertEqual(offsets, [0, 10], "Reopening an already loaded artist reuses the catalog")
    }

    func testFailedSavedCheckDoesNotMisclassifyAlbumsAndRetriesSamePage() async throws {
        let service = service()
        await service.setFailure(true)
        let model = AppModel(service: service)
        model.openArtist(artist)
        let catalog = try XCTUnwrap(model.selectedArtist)
        await model.loadArtistCatalog(catalog)
        XCTAssertTrue(catalog.albums.isEmpty)
        XCTAssertNotNil(catalog.error); XCTAssertEqual(catalog.nextOffset, 0)
        await service.setFailure(false)
        await model.loadArtistCatalog(catalog)
        XCTAssertNil(catalog.error); XCTAssertEqual(catalog.albums.count, 3)
        let offsets = await service.offsets
        XCTAssertEqual(offsets, [0, 0, 10])
    }

    func testSaveAndRemoveMoveAlbumsBetweenSectionsAfterLibraryRefresh() async throws {
        let model = AppModel(service: service())
        model.connection = .connected
        await model.loadPage(offset: 0)
        model.openArtist(artist)
        let catalog = try XCTUnwrap(model.selectedArtist)
        await model.loadArtistCatalog(catalog)
        await model.toggleSaved(album("other"))
        XCTAssertEqual(Set(catalog.albums(saved: true).map(\.id)), ["saved", "other"])
        XCTAssertTrue(model.checkedSavedIDs.contains("older"), "Library refresh must preserve checked artist albums")
        await model.toggleSaved(album("saved"))
        XCTAssertEqual(catalog.albums(saved: true).map(\.id), ["other"])
        XCTAssertEqual(Set(catalog.albums(saved: false).map(\.id)), ["saved", "older"])
    }

    func testSaveWhileCatalogCheckIsPendingWinsOverLateResponse() async throws {
        let service = ArtistService(pages: [0: AlbumPage(albums: [album("other")], nextOffset: nil, total: 1)])
        await service.holdNextCheck()
        let model = AppModel(service: service)
        model.isSearching = true
        model.checkedSavedIDs.insert("other")
        model.openArtist(artist)
        let catalog = try XCTUnwrap(model.selectedArtist)
        let task = Task { await model.loadArtistCatalog(catalog) }
        try await waitForCheck(service)
        await model.toggleSaved(album("other"))
        await service.releaseCheck()
        await task.value
        XCTAssertTrue(catalog.savedIDs.contains("other"))
        XCTAssertTrue(model.savedIDs.contains("other"))
    }

    func testChangingSessionDiscardsLateArtistCatalogAndClearsNavigation() async throws {
        let service = service()
        await service.holdNextCheck()
        let model = AppModel(service: service)
        model.openArtist(artist)
        let catalog = try XCTUnwrap(model.selectedArtist)
        let task = Task { await model.loadArtistCatalog(catalog) }
        try await waitForCheck(service)
        await model.enterDemo()
        model.setForeground(false)
        await service.releaseCheck()
        await task.value
        XCTAssertNil(model.selectedArtist)
        XCTAssertTrue(model.navigationHistory.isEmpty)
        XCTAssertTrue(catalog.albums.isEmpty)
        XCTAssertFalse(model.savedIDs.contains("saved"))
    }
}
