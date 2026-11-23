import Foundation

struct AlbumID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init?(spotifyURI: String) {
        let components = spotifyURI.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3, components[0] == "spotify", components[1] == "album",
              !components[2].isEmpty else { return nil }
        rawValue = String(components[2])
    }
    var uri: String { "spotify:album:\(rawValue)" }
}

struct SpotifyImage: Codable, Hashable, Sendable {
    let url: URL
    let width: Int?
    let height: Int?
}

struct Artist: Codable, Hashable, Sendable {
    let name: String
    let id: String?
    let images: [SpotifyImage]?
    init(name: String, id: String? = nil, images: [SpotifyImage]? = nil) {
        self.name = name; self.id = id; self.images = images
    }
    var portrait: URL? {
        let sorted = (images ?? []).sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        return (sorted.first { ($0.width ?? 0) >= 80 } ?? sorted.last)?.url
    }
}

struct Album: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let artists: [Artist]
    let albumType: String
    let images: [SpotifyImage]
    let releaseDate: String
    let totalTracks: Int
    var restrictions: Restriction?

    struct Restriction: Codable, Hashable, Sendable { let reason: String }
    enum CodingKeys: String, CodingKey {
        case id, name, artists, images, restrictions
        case albumType = "album_type", releaseDate = "release_date", totalTracks = "total_tracks"
    }
    var albumID: AlbumID { AlbumID(rawValue: id) }
    var isAllowed: Bool { albumType == "album" || albumType == "compilation" }
    var artist: String { artists.map(\.name).joined(separator: ", ") }
    var year: String { String(releaseDate.prefix(4)) }
    var releaseYear: Int? {
        guard releaseDate.prefix(4).count == 4, let value = Int(releaseDate.prefix(4)), (1000...9999).contains(value) else { return nil }
        return value
    }
    var artwork: URL? { images.max(by: { ($0.width ?? 0) < ($1.width ?? 0) })?.url }
    var spotifyURL: URL { URL(string: "https://open.spotify.com/album/\(id)")! }
}

enum AlbumSortOrder: String, CaseIterable {
    case library, newestFirst, oldestFirst

    var label: String {
        switch self {
        case .library: "收藏顺序"
        case .newestFirst: "年份：从新到旧"
        case .oldestFirst: "年份：从旧到新"
        }
    }
    func arrange(_ albums: [Album]) -> [Album] {
        guard self != .library else { return albums }
        return albums.enumerated().sorted { lhs, rhs in
            switch (lhs.element.releaseYear, rhs.element.releaseYear) {
            case let (left?, right?) where left != right:
                return self == .newestFirst ? left > right : left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

struct AlbumArtistGroup: Identifiable {
    let id: String
    let name: String?
    let albums: [Album]

    static func make(from albums: [Album], grouped: Bool, order: AlbumSortOrder) -> [Self] {
        let arranged = order.arrange(albums)
        guard grouped else { return [Self(id: "all", name: nil, albums: arranged)] }
        var names: [String: String] = [:]
        let groups = Dictionary(grouping: arranged) { album in
            let artist = album.artists.first?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = artist.isEmpty ? "未知艺人" : artist
            let key = name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if names[key] == nil { names[key] = name }
            return key
        }
        return groups.keys.sorted { (names[$0] ?? $0).localizedStandardCompare(names[$1] ?? $1) == .orderedAscending }
            .map { Self(id: $0, name: names[$0], albums: groups[$0] ?? []) }
    }
}

struct SpotifyPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let next: String?
    let offset: Int
    let total: Int
}

struct AlbumPage: Sendable {
    let albums: [Album]
    let nextOffset: Int?
    let total: Int
}

struct SavedAlbum: Decodable, Sendable { let album: Album }
struct SearchResponse: Decodable, Sendable { let albums: SpotifyPage<Album> }

struct AlbumTrack: Codable, Identifiable, Hashable, Sendable {
    let spotifyID: String?
    let name: String
    let artists: [Artist]
    let durationMS: Int
    let trackNumber: Int
    let discNumber: Int
    var id: String { spotifyID ?? "\(discNumber):\(trackNumber)" }
    enum CodingKeys: String, CodingKey {
        case spotifyID = "id", name, artists
        case durationMS = "duration_ms", trackNumber = "track_number", discNumber = "disc_number"
    }
}

struct PlaybackDevice: Codable, Identifiable, Hashable, Sendable {
    let id: String?
    let name: String
    let type: String
    let isActive: Bool
    let isRestricted: Bool
    let volumePercent: Int?
    let supportsVolume: Bool?
    enum CodingKeys: String, CodingKey {
        case id, name, type
        case isActive = "is_active", isRestricted = "is_restricted"
        case volumePercent = "volume_percent", supportsVolume = "supports_volume"
    }
    var symbol: String {
        switch type.lowercased() {
        case "computer": "desktopcomputer"
        case "smartphone": "iphone"
        case "speaker": "hifispeaker"
        default: "airplay.audio"
        }
    }
    var isSelectable: Bool { id?.isEmpty == false && !isRestricted }
}

struct PlaybackTrack: Decodable, Sendable {
    let id: String?
    let name: String
    let artists: [Artist]
    let durationMS: Int
    let trackNumber: Int?
    let discNumber: Int?
    let album: Album?
    let albumID: AlbumID?
    let albumName: String?
    let artwork: URL?
    let albumTotalTracks: Int?
    enum CodingKeys: String, CodingKey {
        case id, name, artists, album, type
        case durationMS = "duration_ms", trackNumber = "track_number", discNumber = "disc_number"
    }
    init(id: String?, name: String, artists: [Artist], durationMS: Int,
         trackNumber: Int?, discNumber: Int?, album: Album?, albumID: AlbumID? = nil, artwork: URL? = nil,
         albumTotalTracks: Int? = nil, albumName: String? = nil) {
        self.id = id; self.name = name; self.artists = artists; self.durationMS = durationMS
        self.trackNumber = trackNumber; self.discNumber = discNumber; self.album = album
        self.albumID = album?.albumID ?? albumID
        self.albumName = album?.name ?? albumName
        self.artwork = album?.artwork ?? artwork
        self.albumTotalTracks = album?.totalTracks ?? albumTotalTracks
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let type = try c.decodeIfPresent(String.self, forKey: .type), type != "track" {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Not a music track")
        }
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        artists = try c.decodeIfPresent([Artist].self, forKey: .artists) ?? []
        durationMS = try c.decode(Int.self, forKey: .durationMS)
        trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber)
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber)
        // Incomplete nested album metadata must not discard the playing track.
        album = try? c.decodeIfPresent(Album.self, forKey: .album)
        enum AlbumReferenceKeys: String, CodingKey { case id, name, uri, images; case totalTracks = "total_tracks" }
        let reference = try? c.nestedContainer(keyedBy: AlbumReferenceKeys.self, forKey: .album)
        let id = try? reference?.decode(String.self, forKey: .id)
        let uri = try? reference?.decode(String.self, forKey: .uri)
        let images = (try? reference?.decode([SpotifyImage].self, forKey: .images)) ?? []
        albumID = album?.albumID ?? id.flatMap { $0.isEmpty ? nil : AlbumID(rawValue: $0) }
            ?? uri.flatMap { AlbumID(spotifyURI: $0) }
        albumName = album?.name ?? (try? reference?.decode(String.self, forKey: .name))
        artwork = album?.artwork ?? images.max(by: { ($0.width ?? 0) < ($1.width ?? 0) })?.url
        albumTotalTracks = album?.totalTracks ?? (try? reference?.decode(Int.self, forKey: .totalTracks))
    }
}

struct PlaybackContext: Decodable, Sendable {
    let type: String
    let uri: String?
    var albumID: AlbumID? {
        guard type == "album", let uri else { return nil }
        return AlbumID(spotifyURI: uri)
    }
}

struct PlaybackActions: Decodable, Sendable {
    let disallows: [String: Bool]
    init(disallows: [String: Bool] = [:]) { self.disallows = disallows }
    init(from decoder: Decoder) throws {
        // Spotify clients have returned both nested and flattened restrictions.
        let container = try decoder.singleValueContainer()
        if let nested = try? container.decode([String: [String: Bool]].self) {
            disallows = nested["disallows"] ?? [:]
        } else { disallows = (try? container.decode([String: Bool].self)) ?? [:] }
    }
}

struct PlaybackSnapshot: Decodable, Sendable {
    var device: PlaybackDevice?
    var isPlaying: Bool
    var progressMS: Int?
    var item: PlaybackTrack?
    var context: PlaybackContext?
    var shuffleState: Bool?
    var repeatState: String?
    var actions: PlaybackActions?
    var receivedAt: Date = .now
    enum CodingKeys: String, CodingKey {
        case device, item, context, actions
        case isPlaying = "is_playing", progressMS = "progress_ms"
        case shuffleState = "shuffle_state", repeatState = "repeat_state"
    }
    init(device: PlaybackDevice? = nil, isPlaying: Bool = false, progressMS: Int? = nil,
         item: PlaybackTrack? = nil, context: PlaybackContext? = nil,
         shuffleState: Bool? = nil, repeatState: String? = nil, actions: PlaybackActions? = nil) {
        self.device = device; self.isPlaying = isPlaying; self.progressMS = progressMS
        self.item = item; self.context = context; self.shuffleState = shuffleState
        self.repeatState = repeatState; self.actions = actions
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decodeIfPresent(PlaybackDevice.self, forKey: .device)
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        progressMS = try c.decodeIfPresent(Int.self, forKey: .progressMS)
        // Podcasts, ads and unknown item types must not break the player.
        item = try? c.decodeIfPresent(PlaybackTrack.self, forKey: .item)
        context = try c.decodeIfPresent(PlaybackContext.self, forKey: .context)
        shuffleState = try c.decodeIfPresent(Bool.self, forKey: .shuffleState)
        repeatState = try c.decodeIfPresent(String.self, forKey: .repeatState)
        actions = try c.decodeIfPresent(PlaybackActions.self, forKey: .actions)
    }
    func position(at date: Date = .now) -> Double {
        let elapsed = isPlaying ? max(0, date.timeIntervalSince(receivedAt)) * 1000 : 0
        return min(Double(item?.durationMS ?? 0), max(0, Double(progressMS ?? 0) + elapsed)) / 1000
    }
    func allows(_ action: String) -> Bool {
        device?.isRestricted != true && actions?.disallows[action] != true
    }
}

enum PlayerCommand: Sendable {
    case pause, resume, next, previous, seek(Int), volume(Int)
}

protocol SpotifyService: Sendable {
    func album(_ id: AlbumID) async throws -> Album
    func artist(_ id: String) async throws -> Artist?
    func artistAlbums(_ id: String, offset: Int) async throws -> AlbumPage
    func savedAlbums(_ albums: [AlbumID]) async throws -> [Bool]
    func albumTracks(_ album: AlbumID) async throws -> [AlbumTrack]
    func savedAlbums(offset: Int) async throws -> AlbumPage
    func searchAlbums(query: String, offset: Int) async throws -> AlbumPage
    func isSaved(_ album: AlbumID) async throws -> Bool
    func setSaved(_ album: AlbumID, saved: Bool) async throws
    func playback() async throws -> PlaybackSnapshot?
    func devices() async throws -> [PlaybackDevice]
    func transfer(to device: String, play: Bool) async throws
    func playAlbum(_ album: AlbumID, device: String) async throws
    func command(_ command: PlayerCommand, device: String?) async throws
}

extension SpotifyService {
    func album(_ id: AlbumID) async throws -> Album { throw SpotifyError.invalidResponse }
    func artist(_ id: String) async throws -> Artist? { nil }
    func artistAlbums(_ id: String, offset: Int) async throws -> AlbumPage { throw SpotifyError.invalidResponse }
    func savedAlbums(_ albums: [AlbumID]) async throws -> [Bool] {
        var result: [Bool] = []
        for album in albums { result.append(try await isSaved(album)) }
        return result
    }
    func albumTracks(_ album: AlbumID) async throws -> [AlbumTrack] { [] }
}

enum SpotifyError: LocalizedError, Equatable, Sendable {
    case signedOut, invalidClientID, authorizationCancelled, invalidState, authorizationTimeout
    case callbackPortUnavailable(UInt16)
    case noDevice, restricted, rateLimited(seconds: Int), quotaExceeded
    case http(Int, String), invalidResponse, keychain(Int32), playbackUnconfirmed

    var errorDescription: String? {
        switch self {
        case .signedOut: "请连接 Spotify。"
        case .invalidClientID: "请填写有效的 Spotify Client ID。"
        case .authorizationCancelled: "已取消连接。"
        case .invalidState: "登录验证失败，请重新连接。"
        case .authorizationTimeout: "连接超时，请重试。"
        case .callbackPortUnavailable(let port): "登录需要的本机端口 \(port) 被占用，请关闭其他 Albumer 实例或使用该端口的程序后重试。"
        case .noDevice: "未找到播放设备，请打开 Spotify。"
        case .restricted: "Spotify 拒绝了操作。请检查 Premium、应用授权名单及设备限制。"
        case .rateLimited(let seconds): "请求较多，\(seconds) 秒后可重试。"
        case .quotaExceeded: "Spotify API 配额已用完，请稍后重试。"
        case .http(let code, let message): "Spotify \(code)：\(message)"
        case .invalidResponse: "Spotify 返回了无法识别的数据。"
        case .keychain: "无法访问钥匙串。"
        case .playbackUnconfirmed: "Spotify 尚未确认播放，请检查播放设备后重试。"
        }
    }
}

