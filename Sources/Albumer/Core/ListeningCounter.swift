import Foundation

/// Observed listening time only: seeks, paused time, and periods without polling
/// do not count. This is local history, not Spotify's historical stream totals.
struct ListeningCounter: Codable, Sendable {
    private struct Observation: Codable, Sendable {
        var context: String?
        var position: Int
        var playing: Bool
    }
    struct Event {
        var album: String?
        var track: String?
        var isEmpty: Bool { album == nil && track == nil }
    }
    private var previous: Observation?
    private var observedAt: Date?
    private var albumSession: String?
    private var albumCounted = false
    private var trackKey: String?
    private var trackCounted = false
    private var albumSeconds = 0.0
    private var trackSeconds = 0.0

    mutating func observe(_ snapshot: PlaybackSnapshot?, at now: Date = .now) -> Event {
        defer {
            previous = snapshot.map { Observation(context: $0.context?.uri, position: $0.progressMS ?? 0, playing: $0.isPlaying) }
            observedAt = now
        }
        guard let snapshot, let item = snapshot.item, let album = item.album,
              album.isAllowed, snapshot.context?.uri == album.albumID.uri else {
            albumSession = nil; trackKey = nil; return Event()
        }
        let key = item.id ?? "\(album.id):\(item.discNumber ?? 1):\(item.trackNumber ?? 0)"
        let sameTrack = key == trackKey
        if albumSession != album.id {
            albumSession = album.id; albumCounted = false; albumSeconds = 0
        }
        let restarted = key == trackKey && (snapshot.progressMS ?? 0) < 2000 && (previous?.position ?? 0) > 5000
        if key != trackKey || restarted {
            trackKey = key; trackCounted = false; trackSeconds = 0
        }
        guard snapshot.isPlaying, previous?.playing == true, let observedAt,
              sameTrack, previous?.context == snapshot.context?.uri else { return Event() }
        let elapsed = now.timeIntervalSince(observedAt)
        let delta = Double((snapshot.progressMS ?? 0) - (previous?.position ?? 0)) / 1000
        guard elapsed > 0, elapsed <= 45, delta > 0, delta <= elapsed + 2 else { return Event() }
        let seconds = min(delta, elapsed)
        trackSeconds += seconds; albumSeconds += seconds
        var event = Event()
        let threshold = min(30, max(1, Double(item.durationMS) / 2000))
        if !trackCounted && trackSeconds >= threshold { event.track = key; trackCounted = true }
        if !albumCounted && albumSeconds >= 30 { event.album = album.id; albumCounted = true }
        return event
    }
    mutating func beganAlbum() {
        previous = nil; observedAt = nil; albumSession = nil; trackKey = nil
    }
}
