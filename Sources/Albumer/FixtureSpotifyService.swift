import Foundation

// Explicit preview/test mode: no OAuth, network commands, or audio playback.
actor FixtureSpotifyService: SpotifyService {
    static let albums: [Album] = {
        guard let url = Bundle.main.url(forResource: "albums", withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url), let albums = try? JSONDecoder().decode([Album].self, from: data) else { return [] }
        var result = albums
        if ProcessInfo.processInfo.arguments.contains("--edge-cases") {
            result.insert(Album(id: "missing-cover", name: "一张很长名字的专辑 / A Very Long Album Title — Anniversary Edition", artists: [Artist(name: "Lumen Assembly / Sora Vale / Preview Ensemble")], albumType: "compilation", images: [], releaseDate: "2026", totalTracks: 24), at: 0)
        }
        if ProcessInfo.processInfo.arguments.contains("--many-albums"), !result.isEmpty {
            let originals = result
            for index in 0..<60 {
                let source = originals[index % originals.count]
                result.append(Album(id: "preview-extra-\(index)", name: source.name, artists: source.artists,
                                    albumType: source.albumType, images: source.images, releaseDate: source.releaseDate, totalTracks: source.totalTracks))
            }
        }
        return result
    }()
    private struct PreviewTrack: Decodable, Sendable { let title: String; let duration: Int }
    private struct PreviewAlbum: Decodable, Sendable { let id: String; let preview_tracks: [PreviewTrack] }
    private static let tracks: [String: [PreviewTrack]] = {
        guard let url = Bundle.main.url(forResource: "albums", withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url), let albums = try? JSONDecoder().decode([PreviewAlbum].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0.preview_tracks) })
    }()
    private var saved = Set(albums.map(\.id))
    private var index = 0
    private var track = 1
    private var playing = false
    private var position = 42_000
    private var updated = Date.now
    private var volume = 64
    private var deviceID = "preview-mac"
    private var hasStartedPlayback = !ProcessInfo.processInfo.arguments.contains("--idle-device")
    private func trackPosition(_ index: Int, total: Int) -> (disc: Int, number: Int) {
        guard ProcessInfo.processInfo.arguments.contains("--three-discs"), total >= 3 else { return (1, index + 1) }
        let disc = min(2, index * 3 / total)
        return (disc + 1, index - (disc * total + 2) / 3 + 1)
    }
    private var device: PlaybackDevice {
        PlaybackDevice(id: deviceID, name: deviceID == "preview-mac" ? "这台 Mac" : "客厅", type: deviceID == "preview-mac" ? "computer" : "speaker", isActive: true, isRestricted: false, volumePercent: volume, supportsVolume: true)
    }
    func savedAlbums(offset: Int) async throws -> AlbumPage {
        let albums = Self.albums.filter { saved.contains($0.id) }
        return AlbumPage(albums: Array(albums.dropFirst(offset).prefix(20)), nextOffset: offset + 20 < albums.count ? offset + 20 : nil, total: albums.count)
    }
    func album(_ id: AlbumID) async throws -> Album {
        guard let album = Self.albums.first(where: { $0.albumID == id }) else { throw SpotifyError.invalidResponse }
        return album
    }
    func searchAlbums(query: String, offset: Int) async throws -> AlbumPage {
        let albums = Self.albums.filter { "\($0.name) \($0.artist)".localizedCaseInsensitiveContains(query) }
        return AlbumPage(albums: Array(albums.dropFirst(offset).prefix(10)), nextOffset: offset + 10 < albums.count ? offset + 10 : nil, total: albums.count)
    }
    func artistAlbums(_ id: String, offset: Int) async throws -> AlbumPage {
        let albums = Self.albums.filter { $0.artists.contains { $0.id == id } }
        return AlbumPage(albums: Array(albums.dropFirst(offset).prefix(10)),
                         nextOffset: offset + 10 < albums.count ? offset + 10 : nil, total: albums.count)
    }
    func savedAlbums(_ albums: [AlbumID]) async throws -> [Bool] { albums.map { saved.contains($0.rawValue) } }
    func isSaved(_ album: AlbumID) async throws -> Bool { saved.contains(album.rawValue) }
    func albumTracks(_ album: AlbumID) async throws -> [AlbumTrack] {
        let metadata = Self.albums.first { $0.albumID == album }
        return (Self.tracks[album.rawValue] ?? []).enumerated().map { index, track in
            let position = trackPosition(index, total: metadata?.totalTracks ?? 0)
            return AlbumTrack(spotifyID: "\(album.rawValue)-\(index + 1)", name: track.title,
                       artists: metadata?.artists ?? [], durationMS: track.duration, trackNumber: position.number, discNumber: position.disc)
        }
    }
    func setSaved(_ album: AlbumID, saved: Bool) async throws {
        if saved { self.saved.insert(album.rawValue) } else { self.saved.remove(album.rawValue) }
    }
    func playback() async throws -> PlaybackSnapshot? {
        guard hasStartedPlayback, !Self.albums.isEmpty else { return nil }
        let album = Self.albums[index]
        let tracks = Self.tracks[album.id] ?? []
        let current = tracks.indices.contains(track - 1) ? tracks[track - 1] : PreviewTrack(title: "预览曲目", duration: 237000)
        let elapsed = playing ? Int(Date.now.timeIntervalSince(updated) * 1000) : 0
        let trackPosition = trackPosition(track - 1, total: album.totalTracks)
        return PlaybackSnapshot(device: device, isPlaying: playing, progressMS: min(current.duration, position + elapsed),
            item: PlaybackTrack(id: "\(album.id)-\(track)", name: current.title, artists: album.artists, durationMS: current.duration, trackNumber: trackPosition.number, discNumber: trackPosition.disc, album: album),
            context: PlaybackContext(type: "album", uri: album.albumID.uri), shuffleState: false, repeatState: "off", actions: PlaybackActions(disallows: ["skipping_next": track >= album.totalTracks]))
    }
    func devices() async throws -> [PlaybackDevice] {
        [PlaybackDevice(id: "preview-mac", name: "这台 Mac", type: "computer", isActive: hasStartedPlayback && deviceID == "preview-mac", isRestricted: false, volumePercent: volume, supportsVolume: true),
         PlaybackDevice(id: "preview-speaker", name: "客厅", type: "speaker", isActive: hasStartedPlayback && deviceID == "preview-speaker", isRestricted: false, volumePercent: volume, supportsVolume: true)]
    }
    func transfer(to device: String, play: Bool) async throws { deviceID = device; playing = play; updated = .now }
    func playAlbum(_ album: AlbumID, device: String, start: AlbumPlaybackStart) async throws {
        hasStartedPlayback = true
        index = Self.albums.firstIndex { $0.id == album.rawValue } ?? 0
        track = start.trackIndex + 1; position = start.positionMS; playing = true; updated = .now; deviceID = device
    }
    func command(_ command: PlayerCommand, device: String?) async throws {
        if playing { position += Int(Date.now.timeIntervalSince(updated) * 1000) }
        switch command {
        case .pause: playing = false
        case .resume: playing = true
        case .next: track = min(track + 1, Self.albums[index].totalTracks); position = 0
        case .previous: track = max(1, track - 1); position = 0
        case .seek(let ms): position = ms
        case .volume(let v): volume = v
        }
        updated = .now
    }
}
