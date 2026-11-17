import Foundation

actor SpotifyClient: SpotifyService {
    let auth: SpotifyAuth
    private let transport: any HTTPTransport
    private var retryAfter: Date?
    private var quotaExceeded = false
    init(auth: SpotifyAuth, transport: any HTTPTransport = URLSessionTransport()) {
        self.auth = auth; self.transport = transport
    }
    func resetBackoff() { quotaExceeded = false }

    func accountIdentifier() async throws -> String {
        struct Profile: Decodable { let id: String }
        return try JSONDecoder().decode(Profile.self, from: await request("me")).id
    }
    func albumTracks(_ album: AlbumID) async throws -> [AlbumTrack] {
        var tracks: [AlbumTrack] = []
        var offset = 0
        var visited = Set<Int>()
        while visited.count < 100 && visited.insert(offset).inserted {
            let data = try await request("albums/\(album.rawValue)/tracks", query: ["limit": "50", "offset": String(offset)])
            let page = try JSONDecoder().decode(SpotifyPage<AlbumTrack>.self, from: data)
            tracks += page.items
            guard let next = nextOffset(page.next), next > offset else { break }
            offset = next
            try Task.checkCancellation()
        }
        var ids = Set<String>()
        return tracks.filter { ids.insert($0.id).inserted }
    }

    func savedAlbums(offset: Int) async throws -> AlbumPage {
        let data = try await request("me/albums", query: ["limit": "20", "offset": String(offset)])
        let page = try JSONDecoder().decode(SpotifyPage<SavedAlbum>.self, from: data)
        return AlbumPage(albums: page.items.map(\.album).filter(\.isAllowed), nextOffset: nextOffset(page.next), total: page.total)
    }
    func searchAlbums(query: String, offset: Int) async throws -> AlbumPage {
        let data = try await request("search", query: ["q": query, "type": "album", "limit": "10", "offset": String(offset)])
        let page = try JSONDecoder().decode(SearchResponse.self, from: data).albums
        let next = nextOffset(page.next).flatMap { $0 <= 1000 ? $0 : nil }
        return AlbumPage(albums: page.items.filter(\.isAllowed), nextOffset: next, total: page.total)
    }
    func isSaved(_ album: AlbumID) async throws -> Bool {
        let data = try await request("me/library/contains", query: ["uris": album.uri])
        return try JSONDecoder().decode([Bool].self, from: data).first ?? false
    }
    func setSaved(_ album: AlbumID, saved: Bool) async throws {
        _ = try await request("me/library", method: saved ? "PUT" : "DELETE", query: ["uris": album.uri])
    }
    func playback() async throws -> PlaybackSnapshot? {
        let data = try await request("me/player")
        return data.isEmpty ? nil : try JSONDecoder().decode(PlaybackSnapshot.self, from: data)
    }
    func devices() async throws -> [PlaybackDevice] {
        struct Reply: Decodable { let devices: [PlaybackDevice] }
        return try JSONDecoder().decode(Reply.self, from: await request("me/player/devices")).devices
    }
    func transfer(to device: String, play: Bool) async throws {
        struct Body: Encodable { let device_ids: [String]; let play: Bool }
        _ = try await request("me/player", method: "PUT", body: JSONEncoder().encode(Body(device_ids: [device], play: play)))
    }
    func playAlbum(_ album: AlbumID, device: String) async throws {
        guard !album.rawValue.isEmpty else { throw SpotifyError.invalidResponse }
        let session = await auth.sessionVersion()
        _ = try await request("me/player/shuffle", method: "PUT", query: ["state": "false", "device_id": device])
        guard await auth.sessionVersion() == session else { throw CancellationError() }
        _ = try await request("me/player/repeat", method: "PUT", query: ["state": "off", "device_id": device])
        guard await auth.sessionVersion() == session else { throw CancellationError() }
        // 204 means accepted, not applied. Confirm the settings before starting the context.
        var ready = false
        for _ in 0..<5 {
            let state = try await playback()
            guard await auth.sessionVersion() == session else { throw CancellationError() }
            // A newly activated idle device can return 204 until its first context starts.
            if state == nil { ready = true; break }
            if state?.shuffleState == false && state?.repeatState == "off" { ready = true; break }
            try await Task.sleep(for: .milliseconds(400))
        }
        guard ready else { throw SpotifyError.playbackUnconfirmed }
        guard await auth.sessionVersion() == session else { throw CancellationError() }
        struct Offset: Encodable { let position = 0 }
        struct Body: Encodable { let context_uri: String; let offset = Offset(); let position_ms = 0 }
        _ = try await request("me/player/play", method: "PUT", query: ["device_id": device],
                              body: JSONEncoder().encode(Body(context_uri: album.uri)))
    }
    func command(_ command: PlayerCommand, device: String?) async throws {
        var query = device.map { ["device_id": $0] } ?? [:]
        let path: String
        let method: String
        switch command {
        case .pause: path = "pause"; method = "PUT"
        case .resume: path = "play"; method = "PUT"
        case .next: path = "next"; method = "POST"
        case .previous: path = "previous"; method = "POST"
        case .seek(let position): path = "seek"; method = "PUT"; query["position_ms"] = String(max(0, position))
        case .volume(let volume): path = "volume"; method = "PUT"; query["volume_percent"] = String(min(100, max(0, volume)))
        }
        _ = try await request("me/player/\(path)", method: method, query: query)
    }
    private func nextOffset(_ url: String?) -> Int? {
        guard let url, let c = URLComponents(string: url),
              let value = c.queryItems?.first(where: { $0.name == "offset" })?.value else { return nil }
        return Int(value)
    }

    private func request(_ path: String, method: String = "GET", query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        if quotaExceeded { throw SpotifyError.quotaExceeded }
        if let retryAfter, retryAfter > .now { throw SpotifyError.rateLimited(seconds: Int(ceil(retryAfter.timeIntervalSinceNow))) }
        var url = URLComponents(string: "https://api.spotify.com/v1/\(path)")!
        if !query.isEmpty { url.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: url.url!)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var access = try await auth.accessToken()
        for attempt in 0...1 {
            try Task.checkCancellation()
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.data(for: request)
            if (200..<300).contains(response.statusCode) { return data }
            switch response.statusCode {
            case 401 where attempt == 0: access = try await auth.accessToken(rejectedToken: access); continue
            case 401: throw SpotifyError.signedOut
            case 403: throw SpotifyError.restricted
            case 404:
                if path.hasPrefix("me/player") { throw SpotifyError.noDevice }
                throw SpotifyError.http(404, "内容已不可用。")
            case 429:
                struct Reply: Decodable { struct Detail: Decodable { let reason: String? }; let error: Detail }
                if (try? JSONDecoder().decode(Reply.self, from: data).error.reason) == "QUOTA_EXCEEDED" {
                    quotaExceeded = true; throw SpotifyError.quotaExceeded
                }
                let seconds = max(1, Int(response.value(forHTTPHeaderField: "Retry-After") ?? "5") ?? 5)
                retryAfter = Date().addingTimeInterval(Double(seconds))
                throw SpotifyError.rateLimited(seconds: seconds)
            default: throw SpotifyError.http(response.statusCode, "操作未完成，请重试。")
            }
        }
        throw SpotifyError.signedOut
    }
}
