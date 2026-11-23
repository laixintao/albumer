import Foundation

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
