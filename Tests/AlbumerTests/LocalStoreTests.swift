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
        await store.saveArtwork(Data([2]), url: url, generation: generation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let removed = await store.library(account: "two")
        XCTAssertNil(removed)
        // A subsequent connection can cache normally under a new generation.
        await store.saveLibrary(library, account: "one", generation: store.generation())
        let restored = await store.library(account: "one")
        XCTAssertEqual(restored?.nextOffset, 50)
        try await store.removeUserData()
        try await store.removeUserData()
    }

    func testStartupMigrationRemovesLegacyHistoryAndExpiredMetadata() async throws {
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
        let legacy = data.appendingPathComponent("history/old.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy)
        try await store.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        let fresh = await store.library(account: "new")
        XCTAssertNotNil(fresh)
        try await store.prepare()
    }
}
