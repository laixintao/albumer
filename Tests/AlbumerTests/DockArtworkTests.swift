import AppKit
import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

@MainActor
final class DockArtworkTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Artwork did not reach the expected state")
    }

    func testFailedDownloadRetriesAndSuccessfulCoverIsRetained() async throws {
        let original = NSImage(size: NSSize(width: 2, height: 2))
        let cover = NSImage(size: NSSize(width: 4, height: 4))
        let url = URL(string: "https://example.test/cover.jpg")!
        var requests = 0
        var displayed: NSImage?
        let dock = DockArtworkController(originalIcon: { original }, loadImage: { _ in
            requests += 1
            return requests == 1 ? nil : cover
        }, applyImage: { displayed = $0 })
        dock.update(url)
        try await waitUntil { requests == 1 }
        XCTAssertTrue(displayed === original)
        dock.update(url)
        try await waitUntil { displayed === cover }
        XCTAssertEqual(requests, 2)
        dock.update(url)
        XCTAssertEqual(requests, 2, "A displayed cover should not be fetched again on each poll or pause")
        dock.update(nil)
        XCTAssertTrue(displayed === original)
    }

    func testCachedArtworkDoesNotFlashDefaultIcon() {
        let original = NSImage(size: NSSize(width: 2, height: 2))
        let cover = NSImage(size: NSSize(width: 4, height: 4))
        var applied: [NSImage] = []
        let dock = DockArtworkController(originalIcon: { original }, cachedImage: { _ in cover },
                                         loadImage: { _ in XCTFail("Cached artwork must not download"); return nil },
                                         applyImage: { if let image = $0 { applied.append(image) } })
        dock.update(URL(string: "https://example.test/cover.jpg")!)
        XCTAssertEqual(applied.count, 1)
        XCTAssertTrue(applied.first === cover)
    }

    func testLateImagesCannotReplaceNewAlbumOrRestoreAfterPlaybackEnds() async throws {
        let original = NSImage(size: NSSize(width: 2, height: 2))
        let oldCover = NSImage(size: NSSize(width: 4, height: 4))
        let newCover = NSImage(size: NSSize(width: 8, height: 8))
        let first = URL(string: "https://example.test/first.jpg")!
        let second = URL(string: "https://example.test/second.jpg")!
        let third = URL(string: "https://example.test/third.jpg")!
        var pending: [URL: CheckedContinuation<NSImage?, Never>] = [:]
        var applied: [NSImage] = []
        let dock = DockArtworkController(originalIcon: { original }, loadImage: { url in
            await withCheckedContinuation { pending[url] = $0 }
        }, applyImage: { if let image = $0 { applied.append(image) } })
        dock.update(first)
        try await waitUntil { pending[first] != nil }
        dock.update(first)
        XCTAssertEqual(pending.count, 1, "An in-flight request must not be duplicated")
        dock.update(second)
        try await waitUntil { pending[second] != nil }
        try XCTUnwrap(pending.removeValue(forKey: second)).resume(returning: newCover)
        try await waitUntil { applied.last === newCover }
        try XCTUnwrap(pending.removeValue(forKey: first)).resume(returning: oldCover)
        dock.update(third)
        try await waitUntil { pending[third] != nil }
        dock.update(nil)
        try XCTUnwrap(pending.removeValue(forKey: third)).resume(returning: oldCover)
        await Task.yield()
        XCTAssertFalse(applied.contains { $0 === oldCover })
        XCTAssertTrue(applied.last === original)
    }
}
