import Foundation

enum DockPlaybackAction: Sendable { case previous, togglePlayback, next }

struct DockPlaybackInfo {
    let status: String
    let track: String?
    let artist: String?
    let album: String?
    let year: Int?
    let counter: String?
    let device: String?
    let deviceSymbol: String?
    let isPlaying: Bool
    let canGoPrevious: Bool
    let canTogglePlayback: Bool
    let canGoNext: Bool

    init(playback: PlaybackSnapshot?, album: Album?, tracks: [AlbumTrack], connected: Bool, busy: Bool) {
        let item = connected ? playback?.item : nil
        let albumID = item?.albumID ?? playback?.context?.albumID
        let currentAlbum = item == nil ? nil : album.flatMap { $0.albumID == albumID ? $0 : nil }
        isPlaying = item != nil && playback?.isPlaying == true
        status = !connected ? "请连接 Spotify" : (item == nil ? "暂未播放" : (isPlaying ? "正在播放" : "已暂停"))
        track = item?.name
        let names = item?.artists.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ") ?? ""
        artist = item == nil ? nil : (names.isEmpty ? currentAlbum?.artist : names)
        self.album = item?.albumName ?? currentAlbum?.name
        year = currentAlbum?.releaseYear
        let announcement = TrackAnnouncement(state: playback, album: currentAlbum, tracks: tracks)
        counter = item == nil || announcement?.position == nil ? nil : announcement?.counter
        device = item == nil ? nil : playback?.device?.name
        deviceSymbol = item == nil ? nil : playback?.device?.symbol
        let enabled = connected && !busy && item != nil
        canGoPrevious = enabled && playback?.allows("skipping_prev") == true
        canTogglePlayback = enabled && playback?.allows(isPlaying ? "pausing" : "resuming") == true
        canGoNext = enabled && playback?.allows("skipping_next") == true
    }

    func allows(_ action: DockPlaybackAction) -> Bool {
        switch action {
        case .previous: canGoPrevious
        case .togglePlayback: canTogglePlayback
        case .next: canGoNext
        }
    }
}
