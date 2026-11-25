import Foundation

/// Each card finishes its own turn even if the pointer has already moved to another card.
struct AlbumFlipState: Equatable, Sendable {
    enum Phase: Hashable, Sendable {
        case front, turningToBack, back, turningToFront
    }

    private(set) var phase: Phase = .front
    private(set) var wantsBack = false

    mutating func setHighlighted(_ highlighted: Bool, reduceMotion: Bool = false) {
        wantsBack = highlighted
        if reduceMotion {
            phase = highlighted ? .back : .front
        } else if highlighted && phase == .front {
            phase = .turningToBack
        } else if !highlighted && phase == .back {
            phase = .turningToFront
        }
    }

    mutating func finishPhase() {
        switch phase {
        case .turningToBack: phase = wantsBack ? .back : .turningToFront
        case .turningToFront: phase = wantsBack ? .turningToBack : .front
        case .front, .back: break
        }
    }

    mutating func reset(showBack: Bool = false) {
        wantsBack = showBack
        phase = showBack ? .back : .front
    }
}

struct AlbumDisc: Identifiable, Sendable {
    let number: Int
    let tracks: [AlbumTrack]
    var id: Int { number }
    var durationMS: Int { tracks.reduce(0) { $0 + max(0, $1.durationMS) } }

    static func group(_ tracks: [AlbumTrack]) -> [Self] {
        let groups = Dictionary(grouping: tracks, by: \.discNumber)
        return groups.keys.sorted().map { Self(number: $0, tracks: groups[$0] ?? []) }
    }
}

/// The album's ordered tracks share one continuous timeline, including across discs.
struct AlbumTimeline: Sendable {
    let tracks: [AlbumTrack]
    let trackOffsetsMS: [Int]
    let durationMS: Int
    let discNumbers: [Int]

    init?(tracks: [AlbumTrack], expectedTrackCount: Int) {
        guard !tracks.isEmpty, tracks.count == expectedTrackCount,
              tracks.allSatisfy({ $0.durationMS > 0 }) else { return nil }
        self.tracks = tracks
        var offsets: [Int] = []
        var duration = 0
        var discs: [Int] = []
        for track in tracks {
            offsets.append(duration)
            duration += track.durationMS
            if !discs.contains(track.discNumber) { discs.append(track.discNumber) }
        }
        trackOffsetsMS = offsets
        durationMS = duration
        discNumbers = discs
    }

    func positionMS(for start: AlbumPlaybackStart) -> Int? {
        guard tracks.indices.contains(start.trackIndex) else { return nil }
        return trackOffsetsMS[start.trackIndex] + min(tracks[start.trackIndex].durationMS, max(0, start.positionMS))
    }

    func positionMS(for state: PlaybackSnapshot, albumID: AlbumID, at date: Date = .now) -> Int? {
        guard PlaybackIdentity.albumID(for: state, contextTracks: tracks) == albumID,
              let item = state.item, state.progressMS != nil,
              let index = PlaybackIdentity.trackIndex(item, in: tracks, albumID: albumID) else { return nil }
        return positionMS(for: AlbumPlaybackStart(trackIndex: index, positionMS: Int(state.position(at: date) * 1000)))
    }

    func start(at positionMS: Int) -> AlbumPlaybackStart {
        // Keep the endpoint inside the last track instead of jumping out of the album.
        let position = min(durationMS - 1, max(0, positionMS))
        let index = trackOffsetsMS.lastIndex { $0 <= position } ?? 0
        return AlbumPlaybackStart(trackIndex: index, positionMS: position - trackOffsetsMS[index])
    }

    func discNumber(at positionMS: Int) -> Int {
        tracks[start(at: positionMS).trackIndex].discNumber
    }
}
