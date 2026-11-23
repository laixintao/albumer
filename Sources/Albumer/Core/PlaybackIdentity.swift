import Foundation

/// A Spotify track can be relinked to a single release while an album context is playing.
enum PlaybackIdentity {
    static func albumID(for state: PlaybackSnapshot?, contextTracks: [AlbumTrack]? = nil) -> AlbumID? {
        guard let state else { return nil }
        guard let contextID = state.context?.albumID else { return state.item?.albumID }
        if let item = state.item, let itemID = item.albumID, itemID != contextID,
           let contextTracks, trackIndex(item, in: contextTracks, albumID: contextID) == nil {
            // A queued or autoplayed track may leave an old album context behind.
            return itemID
        }
        return contextID
    }

    static func trackIndex(_ item: PlaybackTrack, in tracks: [AlbumTrack], albumID: AlbumID?) -> Int? {
        let identifiers = Set([item.id, item.linkedFromID].compactMap { $0 })
        let exact = tracks.indices.filter { index in
            !identifiers.isDisjoint(with: [tracks[index].spotifyID, tracks[index].linkedFromID].compactMap { $0 })
        }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1, item.albumID == albumID {
            return exact.first { tracks[$0].discNumber == (item.discNumber ?? 1) && tracks[$0].trackNumber == item.trackNumber }
        }
        // Cross-release matches need a unique title, matching artists, and near-identical duration.
        let names = Set(item.artists.map { normalized($0.name) }.filter { !$0.isEmpty })
        let metadata = tracks.indices.filter { index in
            let track = tracks[index]
            return !names.isEmpty && names == Set(track.artists.map { normalized($0.name) })
                && normalized(track.name) == normalized(item.name)
                && item.durationMS > 0 && abs(track.durationMS - item.durationMS) <= 2000
        }
        if metadata.count == 1 { return metadata[0] }
        // Only use a disc-local position when an identifier is missing, in the same release.
        if item.albumID == albumID, let number = item.trackNumber {
            return tracks.indices.first {
                (item.id == nil || tracks[$0].spotifyID == nil)
                    && tracks[$0].trackNumber == number && tracks[$0].discNumber == (item.discNumber ?? 1)
                    && normalized(tracks[$0].name) == normalized(item.name)
            }
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
