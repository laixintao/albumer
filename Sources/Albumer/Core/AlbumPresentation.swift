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
