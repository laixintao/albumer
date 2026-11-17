import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

final class LocalStoreTests: XCTestCase, @unchecked Sendable {
    func testDiskArtworkSurvivesNewStoreAndExpires() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://i.scdn.co/image/one")!
        let data = Data([1, 2, 3, 4])
        let store = LocalStore(cacheRoot: root)
        await store.saveArtwork(data, url: url)
        let reopened = LocalStore(cacheRoot: root)
        let cached = await reopened.artwork(url)
        XCTAssertEqual(cached, data)
        let expired = await reopened.artwork(url, now: .now.addingTimeInterval(31 * 86400))
        XCTAssertNil(expired)
    }
    func testLibraryAndHistoryAreIsolatedAndHistorySurvivesCacheRemoval() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(cacheRoot: root, dataRoot: root.appendingPathComponent("data"))
        await store.saveLibrary(CachedLibrary(albums: [], nextOffset: 50, updatedAt: .now), account: "one")
        await store.saveHistory(ListeningHistory(albums: ["record": 3], tracks: ["song": 4]), account: "one")
        let reopened = LocalStore(cacheRoot: root, dataRoot: root.appendingPathComponent("data"))
        let cached = await reopened.library(account: "one")
        let absent = await reopened.library(account: "two")
        XCTAssertEqual(cached?.nextOffset, 50); XCTAssertNil(absent)
        await reopened.removeAccountCache("one")
        let removed = await reopened.library(account: "one")
        let history = await reopened.history(account: "one")
        let other = await reopened.history(account: "two")
        XCTAssertNil(removed); XCTAssertEqual(history.albums["record"], 3); XCTAssertEqual(history.tracks["song"], 4)
        XCTAssertTrue(other.albums.isEmpty)
    }
}
