import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

final class ListeningCounterTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1000)
    private func snapshot(_ seconds: Int, playing: Bool = true, track: String = "track", duration: Int = 180_000) -> PlaybackSnapshot {
        let album = Album(id: "album", name: "Album", artists: [], albumType: "album", images: [], releaseDate: "2020", totalTracks: 2)
        return PlaybackSnapshot(isPlaying: playing, progressMS: seconds * 1000,
            item: PlaybackTrack(id: track, name: track, artists: [], durationMS: duration, trackNumber: 1, discNumber: 1, album: album),
            context: PlaybackContext(type: "album", uri: album.albumID.uri))
    }
    func testThirtySecondsCountsOnceAndPausingDoesNotIncrement() {
        var counter = ListeningCounter()
        _ = counter.observe(snapshot(0), at: origin)
        var albums = 0; var tracks = 0
        for seconds in stride(from: 5, through: 90, by: 5) {
            let event = counter.observe(snapshot(seconds), at: origin.addingTimeInterval(Double(seconds)))
            if event.album != nil { albums += 1 }; if event.track != nil { tracks += 1 }
        }
        XCTAssertEqual(albums, 1); XCTAssertEqual(tracks, 1)
        let paused = counter.observe(snapshot(90, playing: false), at: origin.addingTimeInterval(110))
        XCTAssertTrue(paused.isEmpty)
        let resumed = counter.observe(snapshot(90), at: origin.addingTimeInterval(130))
        XCTAssertTrue(resumed.isEmpty)
    }
    func testSeekingAndLongPollingGapsDoNotInventListeningTime() {
        var counter = ListeningCounter()
        _ = counter.observe(snapshot(0), at: origin)
        XCTAssertTrue(counter.observe(snapshot(70), at: origin.addingTimeInterval(5)).isEmpty)
        XCTAssertTrue(counter.observe(snapshot(150), at: origin.addingTimeInterval(85)).isEmpty)
        XCTAssertTrue(counter.observe(snapshot(155), at: origin.addingTimeInterval(90)).isEmpty)
        XCTAssertTrue(counter.observe(snapshot(155), at: origin.addingTimeInterval(95)).isEmpty)
    }
    func testNewTrackCountsSeparatelyButAlbumOnlyOncePerSession() {
        var counter = ListeningCounter()
        _ = counter.observe(snapshot(0), at: origin)
        _ = counter.observe(snapshot(30), at: origin.addingTimeInterval(30))
        _ = counter.observe(snapshot(0, track: "next"), at: origin.addingTimeInterval(35))
        let event = counter.observe(snapshot(30, track: "next"), at: origin.addingTimeInterval(65))
        XCTAssertNil(event.album); XCTAssertEqual(event.track, "next")
        counter.beganAlbum()
        _ = counter.observe(snapshot(0), at: origin.addingTimeInterval(70))
        XCTAssertEqual(counter.observe(snapshot(30), at: origin.addingTimeInterval(100)).album, "album")
    }
    func testRestartDoesNotCountAnAlreadyCountedPlaybackAgain() throws {
        var counter = ListeningCounter()
        _ = counter.observe(snapshot(0), at: origin)
        _ = counter.observe(snapshot(30), at: origin.addingTimeInterval(30))
        var restored = try JSONDecoder().decode(ListeningCounter.self, from: JSONEncoder().encode(counter))
        XCTAssertTrue(restored.observe(snapshot(35), at: origin.addingTimeInterval(35)).isEmpty)
        XCTAssertTrue(restored.observe(snapshot(65), at: origin.addingTimeInterval(65)).isEmpty)
    }
    func testShortTrackCountsAfterHalfItsDuration() {
        var counter = ListeningCounter()
        _ = counter.observe(snapshot(0, duration: 20_000), at: origin)
        let event = counter.observe(snapshot(10, duration: 20_000), at: origin.addingTimeInterval(10))
        XCTAssertEqual(event.track, "track"); XCTAssertNil(event.album)
    }
    func testRelinkedSingleCountsTowardItsAlbumContext() {
        let album = snapshot(0).item!.album!
        let single = Album(id: "single", name: "Single", artists: [], albumType: "single", images: [], releaseDate: "2020", totalTracks: 1)
        let original = AlbumTrack(spotifyID: "original", name: "Song", artists: [], durationMS: 180000, trackNumber: 5, discNumber: 1)
        func state(_ seconds: Int) -> PlaybackSnapshot {
            PlaybackSnapshot(isPlaying: true, progressMS: seconds * 1000,
                item: PlaybackTrack(id: "relinked", name: "Song", artists: [], durationMS: 180000,
                    trackNumber: 1, discNumber: 1, album: single),
                context: PlaybackContext(type: "album", uri: album.albumID.uri))
        }
        var counter = ListeningCounter()
        _ = counter.observe(state(0), resolvedAlbum: album, resolvedTrack: original, at: origin)
        let event = counter.observe(state(30), resolvedAlbum: album, resolvedTrack: original, at: origin.addingTimeInterval(30))
        XCTAssertEqual(event.album, album.id)
        XCTAssertEqual(event.track, original.spotifyID)
        var unknown = ListeningCounter()
        _ = unknown.observe(state(0), resolvedAlbum: album, at: origin)
        XCTAssertTrue(unknown.observe(state(30), resolvedAlbum: album, at: origin.addingTimeInterval(30)).isEmpty,
                      "A stale album context without a confirmed track match must not add a play")
    }
    func testAlbumListeningAccumulatesAcrossTracksWithoutCountingTheirBoundaryGap() {
        var counter = ListeningCounter()
        _ = counter.observe(snapshot(0), at: origin)
        XCTAssertNil(counter.observe(snapshot(15), at: origin.addingTimeInterval(15)).album)
        XCTAssertNil(counter.observe(snapshot(0, track: "next"), at: origin.addingTimeInterval(20)).album)
        XCTAssertEqual(counter.observe(snapshot(15, track: "next"), at: origin.addingTimeInterval(35)).album, "album")
    }
}
