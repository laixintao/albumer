import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

final class DockPlaybackInfoTests: XCTestCase {
    private let album = Album(id: "playing", name: "Playing Album", artists: [Artist(name: "Album Artist")],
                              albumType: "album", images: [], releaseDate: "1997-05-21", totalTracks: 13)
    private func state(playing: Bool = true, restrictions: [String: Bool] = [:]) -> PlaybackSnapshot {
        PlaybackSnapshot(device: PlaybackDevice(id: "mac", name: "This Mac", type: "computer", isActive: true,
                                                isRestricted: false, volumePercent: 50, supportsVolume: true),
                         isPlaying: playing, item: PlaybackTrack(id: "song", name: "Current Song", artists: [Artist(name: "Track Artist")],
                                                                durationMS: 180000, trackNumber: 2, discNumber: 1, album: nil,
                                                                albumID: album.albumID),
                         actions: PlaybackActions(disallows: restrictions))
    }
    func testShowsPlayingSongArtistAlbumYearCounterAndDevice() {
        let info = DockPlaybackInfo(playback: state(), album: album, tracks: [], connected: true, busy: false)
        XCTAssertEqual(info.status, "正在播放")
        XCTAssertEqual(info.track, "Current Song")
        XCTAssertEqual(info.artist, "Track Artist")
        XCTAssertEqual(info.album, "Playing Album")
        XCTAssertEqual(info.year, 1997)
        XCTAssertEqual(info.counter, "2/13")
        XCTAssertEqual(info.device, "This Mac")
        XCTAssertEqual(info.deviceSymbol, "desktopcomputer")
        XCTAssertTrue(info.canGoPrevious); XCTAssertTrue(info.canTogglePlayback); XCTAssertTrue(info.canGoNext)
    }
    func testUnrelatedBrowsedAlbumCannotSupplyPlayingAlbumMetadata() {
        let unrelated = Album(id: "browsing", name: "Wrong Album", artists: [Artist(name: "Wrong Artist")],
                              albumType: "album", images: [], releaseDate: "2026", totalTracks: 8)
        let info = DockPlaybackInfo(playback: state(), album: unrelated, tracks: [], connected: true, busy: false)
        XCTAssertEqual(info.track, "Current Song")
        XCTAssertEqual(info.artist, "Track Artist")
        XCTAssertNil(info.album); XCTAssertNil(info.year)
        XCTAssertEqual(info.counter, "2/—")
    }
    func testBusyDisconnectedAndEmptyPlaybackDisableControls() {
        let busy = DockPlaybackInfo(playback: state(), album: album, tracks: [], connected: true, busy: true)
        let disconnected = DockPlaybackInfo(playback: state(), album: album, tracks: [], connected: false, busy: false)
        let empty = DockPlaybackInfo(playback: nil, album: album, tracks: [], connected: true, busy: false)
        for info in [busy, disconnected, empty] {
            XCTAssertFalse(info.allows(.previous)); XCTAssertFalse(info.allows(.togglePlayback)); XCTAssertFalse(info.allows(.next))
        }
        XCTAssertNil(disconnected.track); XCTAssertNil(disconnected.album); XCTAssertNil(disconnected.artist)
        XCTAssertEqual(empty.status, "暂未播放")
    }
    func testSpotifyRestrictionsAndPauseStateAreReflectedInControls() {
        let blocked = DockPlaybackInfo(playback: state(restrictions: ["skipping_next": true, "pausing": true]),
                                       album: album, tracks: [], connected: true, busy: false)
        XCTAssertFalse(blocked.canGoNext); XCTAssertFalse(blocked.canTogglePlayback); XCTAssertTrue(blocked.canGoPrevious)
        let paused = DockPlaybackInfo(playback: state(playing: false), album: album, tracks: [], connected: true, busy: false)
        XCTAssertEqual(paused.status, "已暂停"); XCTAssertFalse(paused.isPlaying); XCTAssertTrue(paused.canTogglePlayback)
        let cannotResume = DockPlaybackInfo(playback: state(playing: false, restrictions: ["resuming": true]),
                                            album: album, tracks: [], connected: true, busy: false)
        XCTAssertFalse(cannotResume.canTogglePlayback)
    }
}
