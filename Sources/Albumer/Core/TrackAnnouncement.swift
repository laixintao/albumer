import Foundation

struct TrackAnnouncement: Equatable, Sendable {
    let id: String
    let name: String
    let artworkURL: URL?
    let position: Int?
    let total: Int?

    var counter: String { "\(position.map(String.init) ?? "—")/\(total.map(String.init) ?? "—")" }

    init?(state: PlaybackSnapshot?, album: Album?, tracks: [AlbumTrack]) {
        guard let track = state?.item, !track.name.isEmpty else { return nil }
        id = track.id.map { "track:\($0)" }
            ?? "\(track.albumID?.rawValue ?? state?.context?.uri ?? ""):\(track.discNumber ?? 1):\(track.trackNumber ?? 0):\(track.name):\(track.artists.map(\.name).joined(separator: ","))"
        name = track.name
        let playingAlbumID = track.albumID ?? state?.context?.albumID
        let matchingAlbum = album.flatMap { $0.albumID == playingAlbumID ? $0 : nil }
        artworkURL = track.artwork ?? matchingAlbum?.artwork
        let knownTotal = track.albumTotalTracks ?? matchingAlbum?.totalTracks
        let ordered = tracks.sorted {
            $0.discNumber == $1.discNumber ? $0.trackNumber < $1.trackNumber : $0.discNumber < $1.discNumber
        }
        let completeTracks = !ordered.isEmpty && (knownTotal == nil || ordered.count == knownTotal)
        total = knownTotal.flatMap { $0 > 0 ? $0 : nil } ?? (completeTracks ? ordered.count : nil)
        if completeTracks, let index = ordered.firstIndex(where: {
            if let id = track.id, $0.spotifyID == id { return true }
            return $0.discNumber == (track.discNumber ?? 1) && $0.trackNumber == track.trackNumber
        }) {
            position = index + 1
        } else if (track.discNumber ?? 1) == 1, let number = track.trackNumber, number > 0,
                  total.map({ number <= $0 }) ?? true {
            position = number
        } else {
            // A disc-local track number is not the position in the whole album.
            position = nil
        }
    }
}

/// Owns the delay and dwell independently of the main window and polling frequency.
@MainActor
final class TrackAnnouncementController {
    private let wait: @MainActor (Duration) async throws -> Void
    private let present: @MainActor (TrackAnnouncement) -> Void
    private let dismiss: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var latest: TrackAnnouncement?
    private var playing = false
    private var announced = false
    private var visible = false

    init(wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         present: @escaping @MainActor (TrackAnnouncement) -> Void = { _ in },
         dismiss: @escaping @MainActor () -> Void = {}) {
        self.wait = wait; self.present = present; self.dismiss = dismiss
    }

    func update(_ announcement: TrackAnnouncement?, isPlaying: Bool) {
        guard let announcement else { reset(); return }
        if latest?.id != announcement.id {
            cancelPresentation()
            announced = false
        }
        let changed = latest != announcement
        latest = announcement
        playing = isPlaying
        guard isPlaying else { cancelPresentation(); return }
        if visible, changed { present(announcement) }
        guard !announced, task == nil else { return }
        let generation = generation
        task = Task {
            do {
                try await wait(.seconds(1))
                try Task.checkCancellation()
                guard generation == self.generation, playing, let latest else { return }
                announced = true; visible = true
                present(latest)
                try await wait(.seconds(5))
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                visible = false; task = nil
                dismiss()
            } catch { /* A newer track, pause, or account change cancels this presentation. */ }
        }
    }

    func reset() {
        cancelPresentation()
        latest = nil; playing = false; announced = false
    }

    private func cancelPresentation() {
        generation += 1
        task?.cancel(); task = nil
        if visible { dismiss(); visible = false }
    }
}
