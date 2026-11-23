import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

final class PlaybackIdentityTests: XCTestCase {
    private let artist = Artist(name: "Fixture Artist", id: "artist")
    private var record: Album {
        Album(id: "record", name: "Full Album", artists: [artist], albumType: "album",
              images: [SpotifyImage(url: URL(string: "https://example.test/album.png")!, width: 640, height: 640)],
              releaseDate: "2021", totalTracks: 10)
    }
    private var single: Album {
        Album(id: "single", name: "Single Release", artists: [artist], albumType: "single",
              images: [SpotifyImage(url: URL(string: "https://example.test/single.png")!, width: 640, height: 640)],
              releaseDate: "2020", totalTracks: 1)
    }
    private var tracks: [AlbumTrack] {
        (1...10).map { AlbumTrack(spotifyID: "song-\($0)", name: "Song \($0)", artists: [artist],
                                  durationMS: 180000, trackNumber: $0, discNumber: 1) }
    }
    private func state(id: String = "song-5", name: String = "Song 5", linked: String? = nil) -> PlaybackSnapshot {
        PlaybackSnapshot(isPlaying: true, item: PlaybackTrack(id: id, name: name, artists: [artist], durationMS: 180500,
            trackNumber: 1, discNumber: 1, album: single, linkedFromID: linked),
            context: PlaybackContext(type: "album", uri: record.albumID.uri))
    }

    func testSingleReleaseInsideAlbumUsesAlbumCoverAndActualTrackPosition() {
        let state = state()
        XCTAssertEqual(PlaybackIdentity.albumID(for: state, contextTracks: tracks), record.albumID)
        XCTAssertEqual(PlaybackIdentity.trackIndex(state.item!, in: tracks, albumID: record.albumID), 4)
        let toast = TrackAnnouncement(state: state, album: record, tracks: tracks)
        XCTAssertEqual(toast?.album, record)
        XCTAssertEqual(toast?.albumID, record.albumID)
        XCTAssertEqual(toast?.artworkURL, record.artwork)
        XCTAssertEqual(toast?.counter, "5/10")
        let dock = DockPlaybackInfo(playback: state, album: record, tracks: tracks, connected: true, busy: false)
        XCTAssertEqual(dock.album, record.name)
        XCTAssertEqual(dock.year, 2021)
        XCTAssertEqual(dock.counter, "5/10")
    }

    func testRelinkingUsesOriginalIdentifierBeforeTrackNumber() {
        let state = state(id: "market-relinked", name: "Different localized title", linked: "song-5")
        XCTAssertEqual(PlaybackIdentity.trackIndex(state.item!, in: tracks, albumID: record.albumID), 4)
        XCTAssertEqual(TrackAnnouncement(state: state, album: record, tracks: tracks)?.counter, "5/10")
    }

    func testDifferentReleaseIdentifiersRequireUniqueMetadataMatch() {
        let item = state(id: "single-edition").item!
        XCTAssertEqual(PlaybackIdentity.trackIndex(item, in: tracks, albumID: record.albumID), 4)
        var ambiguous = tracks
        ambiguous.append(AlbumTrack(spotifyID: "duplicate", name: "Song 5", artists: [artist], durationMS: 180500, trackNumber: 11, discNumber: 1))
        XCTAssertNil(PlaybackIdentity.trackIndex(item, in: ambiguous, albumID: record.albumID))
        let unrelated = state(id: "different", name: "Unrelated Song")
        XCTAssertEqual(PlaybackIdentity.albumID(for: unrelated, contextTracks: tracks), single.albumID)
    }

    func testUnknownContextDoesNotBorrowSingleCoverOrTrackOne() {
        let toast = TrackAnnouncement(state: state(), album: nil, tracks: [])
        XCTAssertEqual(toast?.albumID, record.albumID)
        XCTAssertNil(toast?.artworkURL)
        XCTAssertNil(toast?.position)
        XCTAssertNil(toast?.total)
    }

    func testPlaylistSingleRemainsItsOwnRelease() {
        var state = state()
        state.context = PlaybackContext(type: "playlist", uri: "spotify:playlist:mix")
        XCTAssertEqual(PlaybackIdentity.albumID(for: state), single.albumID)
        let toast = TrackAnnouncement(state: state, album: single, tracks: [])
        XCTAssertEqual(toast?.counter, "1/1")
        XCTAssertEqual(toast?.artworkURL, single.artwork)
    }

    func testExactIdentifierWinsOverEarlierRowWithSameDiscPosition() {
        let item = PlaybackTrack(id: "song-5", name: "Song 5", artists: [artist], durationMS: 180000,
                                 trackNumber: 1, discNumber: 1, album: record)
        XCTAssertEqual(PlaybackIdentity.trackIndex(item, in: tracks, albumID: record.albumID), 4)
    }

    func testLinkedFromDecodesInBothEndpoints() throws {
        let base = #"{"id":"replacement","name":"Song","artists":[],"duration_ms":180000,"track_number":1,"disc_number":1,"linked_from":{"id":"original"}}"#
        let data = Data(base.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackTrack.self, from: data).linkedFromID, "original")
        XCTAssertEqual(try JSONDecoder().decode(AlbumTrack.self, from: data).linkedFromID, "original")
    }
}
