import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

final class LocalStoreTests: XCTestCase, @unchecked Sendable {
    func testDiskArtworkSurvivesNewStoreAndExpires() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://example.test/one.png")!
        let data = Data([1, 2, 3, 4])
        let store = LocalStore(cacheRoot: root)
        await store.saveArtwork(data, url: url, generation: store.generation())
        let reopened = LocalStore(cacheRoot: root)
        let cached = await reopened.artwork(url)
        XCTAssertEqual(cached, data)
        let expired = await reopened.artwork(url, now: .now.addingTimeInterval(8 * 86400))
        XCTAssertNil(expired)
    }

    func testDisconnectRemovesAllAccountDataAndRejectsLateWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(cacheRoot: root.appendingPathComponent("cache"), dataRoot: root.appendingPathComponent("data"))
        let generation = await store.generation()
        let library = CachedLibrary(albums: [], nextOffset: 50, updatedAt: .now)
        let url = URL(string: "https://example.test/cover.png")!
        await store.saveLibrary(library, account: "one", generation: generation)
        await store.saveLibrary(library, account: "two", generation: generation)
        await store.savePreferredDeviceID("private-device", account: "one", generation: generation)
        let positions = ["record": AlbumPlaybackPosition(trackID: "track", linkedFromID: nil, discNumber: 2, trackNumber: 3, positionMS: 42000)]
        await store.savePlaybackPositions(positions, account: "one", generation: generation)
        await store.savePlaybackPositions(positions, account: "two", generation: generation)
        var history = ListeningHistory()
        history.albums["record"] = 7
        await store.saveHistory(history, account: "one", generation: generation)
        await store.saveArtwork(Data([1]), url: url, generation: generation)
        let absent = await store.library(account: "three")
        XCTAssertNil(absent)
        let legacy = root.appendingPathComponent("data/history/old.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"albums\":{\"record\":3}}".utf8).write(to: legacy)
        try await store.removeUserData()
        await store.saveLibrary(library, account: "one", generation: generation)
        await store.saveTracks([], album: "record", account: "one", generation: generation)
        await store.savePreferredDeviceID("late-device", account: "one", generation: generation)
        await store.savePlaybackPositions(positions, account: "one", generation: generation)
        await store.saveArtwork(Data([2]), url: url, generation: generation)
        await store.saveHistory(history, account: "one", generation: generation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/playback").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/history").path))
        let removed = await store.library(account: "two")
        XCTAssertNil(removed)
        // A subsequent connection can cache normally under a new generation.
        await store.saveLibrary(library, account: "one", generation: store.generation())
        let restored = await store.library(account: "one")
        XCTAssertEqual(restored?.nextOffset, 50)
        try await store.removeUserData()
        try await store.removeUserData()
    }

    func testResumePositionsSurviveRestartAndCacheExpirationAndStayAccountScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache"), data = root.appendingPathComponent("data")
        let store = LocalStore(cacheRoot: cache, dataRoot: data)
        let positions = [
            "one": AlbumPlaybackPosition(trackID: "track-3", linkedFromID: nil, discNumber: 1, trackNumber: 3, positionMS: 42000),
            "two": AlbumPlaybackPosition(trackID: "track-9", linkedFromID: "original", discNumber: 2, trackNumber: 2, positionMS: 18000)
        ]
        await store.savePlaybackPositions(positions, account: "one", generation: store.generation())
        let reopened = LocalStore(cacheRoot: cache, dataRoot: data)
        try await reopened.prepare(now: .now.addingTimeInterval(30 * 86400))
        let restored = await reopened.playbackPositions(account: "one")
        let other = await reopened.playbackPositions(account: "two")
        XCTAssertEqual(restored, positions)
        XCTAssertTrue(other.isEmpty)
    }

    func testStartupPreservesLegacyHistoryWhileExpiringMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let data = root.appendingPathComponent("data")
        let store = LocalStore(cacheRoot: cache, dataRoot: data)
        let generation = await store.generation()
        await store.saveLibrary(CachedLibrary(albums: [], nextOffset: 10, updatedAt: .now), account: "old", generation: generation)
        await store.saveLibrary(CachedLibrary(albums: [], nextOffset: nil, updatedAt: .now), account: "new", generation: generation)
        let old = cache.appendingPathComponent("accounts/\(LocalStore.key("old"))/library.json")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-8 * 86400)], ofItemAtPath: old.path)
        let legacy = data.appendingPathComponent("history/\(LocalStore.key("old")).json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"albums\":{\"record\":7},\"tracks\":{\"song\":12}}".utf8).write(to: legacy)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-90 * 86400)], ofItemAtPath: legacy.path)
        try await store.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        let history = await store.history(account: "old")
        XCTAssertEqual(history.albums["record"], 7)
        XCTAssertEqual(history.tracks["song"], 12)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        let fresh = await store.library(account: "new")
        XCTAssertNotNil(fresh)
        try await store.prepare()
    }

    func testListeningTotalsSurviveRestartAndRemainAccountScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache"), data = root.appendingPathComponent("data")
        let store = LocalStore(cacheRoot: cache, dataRoot: data)
        var history = ListeningHistory()
        history.albums["record"] = 12
        history.tracks["song"] = 19
        await store.saveHistory(history, account: "one", generation: store.generation())
        let reopened = LocalStore(cacheRoot: cache, dataRoot: data)
        try await reopened.prepare(now: .now.addingTimeInterval(90 * 86400))
        let restored = await reopened.history(account: "one")
        let other = await reopened.history(account: "two")
        XCTAssertEqual(restored.albums, history.albums)
        XCTAssertEqual(restored.tracks, history.tracks)
        XCTAssertTrue(other.albums.isEmpty)
    }
}
