import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

final class AlbumPresentationTests: XCTestCase {
    private func track(_ name: String, disc: Int, number: Int, duration: Int) -> AlbumTrack {
        AlbumTrack(spotifyID: nil, name: name, artists: [], durationMS: duration, trackNumber: number, discNumber: disc)
    }

    func testDiscsSeparateRestartedTrackNumbersAndKeepTheirOwnDurations() {
        let first = track("First", disc: 1, number: 1, duration: 60_000)
        let second = track("Second", disc: 1, number: 2, duration: 120_000)
        let nextDisc = track("Another first", disc: 2, number: 1, duration: 90_000)
        let discs = AlbumDisc.group([nextDisc, first, second])
        XCTAssertEqual(discs.map(\.number), [1, 2])
        XCTAssertEqual(discs[0].tracks, [first, second])
        XCTAssertEqual(discs[1].tracks, [nextDisc])
        XCTAssertEqual(discs.map(\.durationMS), [180_000, 90_000])
        XCTAssertNotEqual(discs[0].tracks[0].id, discs[1].tracks[0].id, "Track 1 on two discs must remain distinct for playback highlighting and scrolling")
    }

    func testSingleDiscAndEmptyAlbumsNeedNoExtraPartitions() {
        XCTAssertTrue(AlbumDisc.group([]).isEmpty)
        let tracks = [track("One", disc: 1, number: 1, duration: 1000),
                      track("Two", disc: 1, number: 2, duration: 2000)]
        let discs = AlbumDisc.group(tracks)
        XCTAssertEqual(discs.count, 1)
        XCTAssertEqual(discs[0].tracks, tracks)
    }
}
