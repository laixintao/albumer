import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

@MainActor
private final class AnnouncementClock {
    struct Wait {
        let duration: Duration
        var continuation: CheckedContinuation<Void, Error>?
    }
    var waits: [Wait] = []
    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            waits.append(Wait(duration: duration, continuation: continuation))
        }
    }
    func advance(_ index: Int) {
        let continuation = waits[index].continuation
        waits[index].continuation = nil
        continuation?.resume()
    }
    func cancelRemaining() {
        for index in waits.indices {
            let continuation = waits[index].continuation
            waits[index].continuation = nil
            continuation?.resume(throwing: CancellationError())
        }
    }
}

@MainActor
final class TrackAnnouncementTests: XCTestCase {
    private func snapshot(_ name: String = "Song", id: String = "song", number: Int = 2, disc: Int = 1,
                          total: Int? = 13, playing: Bool = true, artwork: URL? = nil) -> PlaybackSnapshot {
        PlaybackSnapshot(isPlaying: playing, progressMS: 0,
                         item: PlaybackTrack(id: id, name: name, artists: [], durationMS: 180000,
                                             trackNumber: number, discNumber: disc, album: nil,
                                             albumID: AlbumID(rawValue: "album"), artwork: artwork, albumTotalTracks: total))
    }
    private func announcement(_ id: String, total: Int? = 13, artwork: URL? = nil) -> TrackAnnouncement {
        TrackAnnouncement(state: snapshot(id, id: id, total: total, artwork: artwork), album: nil, tracks: [])!
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Announcement did not reach the expected state")
    }

    func testWaitsOneSecondThenDwellsFiveSecondsWithoutRestartingOnPolls() async throws {
        let clock = AnnouncementClock()
        defer { clock.cancelRemaining() }
        var shown: [TrackAnnouncement] = []
        var hidden = 0
        let controller = TrackAnnouncementController(wait: { try await clock.sleep($0) }, present: { shown.append($0) }, dismiss: { hidden += 1 })
        let song = announcement("A")
        controller.update(song, isPlaying: true)
        try await waitUntil { clock.waits.count == 1 }
        XCTAssertEqual(clock.waits[0].duration, .seconds(1))
        XCTAssertTrue(shown.isEmpty)
        controller.update(song, isPlaying: true)
        XCTAssertEqual(clock.waits.count, 1)
        clock.advance(0)
        try await waitUntil { clock.waits.count == 2 }
        XCTAssertEqual(shown, [song])
        XCTAssertEqual(clock.waits[1].duration, .seconds(5))
        controller.update(song, isPlaying: true)
        XCTAssertEqual(clock.waits.count, 2)
        clock.advance(1)
        try await waitUntil { hidden == 1 }
        controller.update(song, isPlaying: true)
        XCTAssertEqual(clock.waits.count, 2)
        XCTAssertEqual(shown.count, 1)
    }
    func testQuickSkipDiscardsCancelledTrackEvenIfItsTimerFinishesLate() async throws {
        let clock = AnnouncementClock()
        defer { clock.cancelRemaining() }
        var shown: [String] = []
        let controller = TrackAnnouncementController(wait: { try await clock.sleep($0) }, present: { shown.append($0.name) })
        controller.update(announcement("A"), isPlaying: true)
        try await waitUntil { clock.waits.count == 1 }
        controller.update(announcement("B"), isPlaying: true)
        try await waitUntil { clock.waits.count == 2 }
        clock.advance(0)
        clock.advance(1)
        try await waitUntil { shown == ["B"] }
        XCTAssertFalse(shown.contains("A"))
        controller.reset()
    }
    func testPauseBeforeDisplayCancelsDelayAndResumeAfterDisplayDoesNotRepeat() async throws {
        let clock = AnnouncementClock()
        defer { clock.cancelRemaining() }
        var shown = 0
        var hidden = 0
        let controller = TrackAnnouncementController(wait: { try await clock.sleep($0) }, present: { _ in shown += 1 }, dismiss: { hidden += 1 })
        let song = announcement("A")
        controller.update(song, isPlaying: true)
        try await waitUntil { clock.waits.count == 1 }
        controller.update(song, isPlaying: false)
        clock.advance(0)
        controller.update(song, isPlaying: true)
        try await waitUntil { clock.waits.count == 2 }
        XCTAssertEqual(shown, 0)
        clock.advance(1)
        try await waitUntil { clock.waits.count == 3 }
        XCTAssertEqual(shown, 1)
        controller.update(song, isPlaying: false)
        XCTAssertEqual(hidden, 1)
        controller.update(song, isPlaying: true)
        XCTAssertEqual(clock.waits.count, 3)
        XCTAssertEqual(shown, 1)
    }
    func testMetadataUpdatesUseSameTimerAndOldDismissCannotHideNewSong() async throws {
        let clock = AnnouncementClock()
        defer { clock.cancelRemaining() }
        var shown: [TrackAnnouncement] = []
        var hidden = 0
        let controller = TrackAnnouncementController(wait: { try await clock.sleep($0) }, present: { shown.append($0) }, dismiss: { hidden += 1 })
        controller.update(announcement("A", total: nil), isPlaying: true)
        try await waitUntil { clock.waits.count == 1 }
        controller.update(announcement("A"), isPlaying: true)
        clock.advance(0)
        try await waitUntil { clock.waits.count == 2 }
        XCTAssertEqual(shown.last?.counter, "2/13")
        let cover = URL(string: "https://example.test/album.jpg")!
        controller.update(announcement("A", artwork: cover), isPlaying: true)
        XCTAssertEqual(shown.last?.artworkURL, cover)
        XCTAssertEqual(clock.waits.count, 2, "Late artwork must not restart the five-second dwell")
        controller.update(announcement("B"), isPlaying: true)
        try await waitUntil { clock.waits.count == 3 }
        XCTAssertEqual(hidden, 1)
        clock.advance(2)
        try await waitUntil { clock.waits.count == 4 }
        clock.advance(1)
        await Task.yield()
        XCTAssertEqual(shown.last?.name, "B")
        XCTAssertEqual(hidden, 1, "A cancelled dwell timer cannot dismiss a newer track")
        controller.reset()
        XCTAssertEqual(hidden, 2)
    }
    func testResetAndStoppedPlaybackCancelPendingPresentation() async throws {
        let clock = AnnouncementClock()
        defer { clock.cancelRemaining() }
        var shown = 0
        let controller = TrackAnnouncementController(wait: { try await clock.sleep($0) }, present: { _ in shown += 1 })
        controller.update(announcement("A"), isPlaying: true)
        try await waitUntil { clock.waits.count == 1 }
        controller.reset()
        clock.advance(0)
        controller.update(announcement("B"), isPlaying: false)
        await Task.yield()
        XCTAssertEqual(shown, 0)
        XCTAssertEqual(clock.waits.count, 1)
        controller.update(nil, isPlaying: false)
    }
    func testOpeningToastConsumesItWithoutSuppressingNextTrack() async throws {
        let clock = AnnouncementClock()
        defer { clock.cancelRemaining() }
        var shown: [String] = []
        var hidden = 0
        let controller = TrackAnnouncementController(wait: { try await clock.sleep($0) },
                                                    present: { shown.append($0.id) }, dismiss: { hidden += 1 })
        controller.update(announcement("A"), isPlaying: true)
        try await waitUntil { clock.waits.count == 1 }
        clock.advance(0)
        try await waitUntil { clock.waits.count == 2 }
        controller.dismiss(announcement("A").id)
        XCTAssertEqual(hidden, 1)
        controller.update(announcement("A", artwork: URL(string: "https://example.test/late.jpg")), isPlaying: true)
        XCTAssertEqual(shown, [announcement("A").id])
        controller.update(announcement("B"), isPlaying: true)
        try await waitUntil { clock.waits.count == 3 }
        controller.dismiss(announcement("A").id)
        clock.advance(2)
        try await waitUntil { shown.last == announcement("B").id }
        clock.advance(1)
        await Task.yield()
        XCTAssertEqual(hidden, 1, "The consumed toast's old timer must not dismiss the next song")
        controller.reset()
    }

    func testToastDestinationUsesTrackAlbumAndNeverUnrelatedBrowsingOrPlaylist() {
        let record = Album(id: "album", name: "Record", artists: [], albumType: "album", images: [], releaseDate: "2020", totalTracks: 13)
        let matching = TrackAnnouncement(state: snapshot(), album: record, tracks: [])
        XCTAssertEqual(matching?.albumID, record.albumID)
        XCTAssertEqual(matching?.album, record)
        let track = PlaybackTrack(id: "track", name: "Song", artists: [], durationMS: 180000,
                                  trackNumber: 1, discNumber: 1, album: nil)
        let playlist = PlaybackSnapshot(isPlaying: true, item: track,
                                        context: PlaybackContext(type: "playlist", uri: "spotify:playlist:other"))
        let unknown = TrackAnnouncement(state: playlist, album: record, tracks: [])
        XCTAssertNil(unknown?.albumID)
        XCTAssertNil(unknown?.album)
    }
    func testArtworkFallsBackOnlyToThePlayingAlbumAndPrefersPlaybackImage() {
        let cover = URL(string: "https://example.test/library.jpg")!
        let playingCover = URL(string: "https://example.test/playing.jpg")!
        func album(_ id: String) -> Album {
            Album(id: id, name: id, artists: [], albumType: "album",
                  images: [SpotifyImage(url: cover, width: 640, height: 640)], releaseDate: "2020", totalTracks: 13)
        }
        XCTAssertEqual(TrackAnnouncement(state: snapshot(), album: album("album"), tracks: [])?.artworkURL, cover)
        XCTAssertNil(TrackAnnouncement(state: snapshot(), album: album("unrelated"), tracks: [])?.artworkURL)
        XCTAssertEqual(TrackAnnouncement(state: snapshot(artwork: playingCover), album: album("album"), tracks: [])?.artworkURL, playingCover)
    }
    func testSecondDiscUsesAlbumWideTrackPosition() {
        let tracks = (1...13).map { number in
            AlbumTrack(spotifyID: "song-\(number)", name: "Song \(number)", artists: [], durationMS: 180000,
                       trackNumber: number <= 7 ? number : number - 7, discNumber: number <= 7 ? 1 : 2)
        }
        let state = snapshot(id: "song-9", number: 2, disc: 2)
        let announcement = TrackAnnouncement(state: state, album: nil, tracks: tracks.reversed())
        XCTAssertEqual(announcement?.counter, "9/13")
        let partial = TrackAnnouncement(state: state, album: nil, tracks: [])
        XCTAssertEqual(partial?.counter, "—/13", "Never label track two of disc two as track two of the whole album")
    }
    func testPartialSpotifyAlbumRetainsCountAndMissingCountStaysUnknown() throws {
        let state = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data("""
        {"is_playing":true,"item":{"id":"song","name":"Song","duration_ms":180000,
         "track_number":2,"disc_number":1,"album":{"id":"album","total_tracks":13,
         "images":[{"url":"https://example.test/partial.jpg","width":640,"height":640}]}}}
        """.utf8))
        XCTAssertNil(state.item?.album)
        XCTAssertEqual(state.item?.albumTotalTracks, 13)
        XCTAssertEqual(TrackAnnouncement(state: state, album: nil, tracks: [])?.artworkURL?.absoluteString, "https://example.test/partial.jpg")
        XCTAssertEqual(TrackAnnouncement(state: state, album: nil, tracks: [])?.counter, "2/13")
        XCTAssertEqual(TrackAnnouncement(state: snapshot(total: nil), album: nil, tracks: [])?.counter, "2/—")
    }
}
