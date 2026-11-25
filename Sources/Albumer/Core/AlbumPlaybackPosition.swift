import Foundation

struct AlbumPlaybackStart: Equatable, Sendable {
    let trackIndex: Int
    let positionMS: Int
    static let beginning = Self(trackIndex: 0, positionMS: 0)
}

/// One replaceable resume point per album, without a listening history or counters.
struct AlbumPlaybackPosition: Codable, Equatable, Sendable {
    let trackID: String
    let linkedFromID: String?
    let discNumber: Int?
    let trackNumber: Int?
    let positionMS: Int

    func start(in tracks: [AlbumTrack]) -> AlbumPlaybackStart? {
        let identifiers = Set([trackID, linkedFromID].compactMap { $0 })
        let matches = tracks.indices.filter {
            !identifiers.isDisjoint(with: [tracks[$0].spotifyID, tracks[$0].linkedFromID].compactMap { $0 })
        }
        let index: Int?
        if matches.count == 1 { index = matches.first }
        else {
            let numbered = matches.filter { tracks[$0].discNumber == discNumber && tracks[$0].trackNumber == trackNumber }
            index = numbered.count == 1 ? numbered.first : nil
        }
        guard let index else { return nil }
        // A completed track continues with the next one; a completed album starts over.
        if tracks[index].durationMS > 0, positionMS >= tracks[index].durationMS {
            return index + 1 < tracks.count ? AlbumPlaybackStart(trackIndex: index + 1, positionMS: 0) : .beginning
        }
        return AlbumPlaybackStart(trackIndex: index, positionMS: max(0, positionMS))
    }
}
