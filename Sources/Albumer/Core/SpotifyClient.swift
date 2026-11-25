import Foundation

actor SpotifyClient: SpotifyService {
    let auth: SpotifyAuth
    private let transport: any HTTPTransport
    private let retry: NetworkRetry
    private var retryAfter: Date?
    private var quotaExceeded = false
    init(auth: SpotifyAuth, transport: any HTTPTransport = URLSessionTransport(), retry: NetworkRetry = NetworkRetry()) {
        self.auth = auth; self.transport = transport; self.retry = retry
    }
    func resetBackoff() { quotaExceeded = false }

    func album(_ id: AlbumID) async throws -> Album {
        try JSONDecoder().decode(Album.self, from: await request("albums/\(id.rawValue)"))
    }

    func artist(_ id: String) async throws -> Artist? {
        try JSONDecoder().decode(Artist.self, from: await request("artists/\(id)"))
    }

    func artistAlbums(_ id: String, offset: Int) async throws -> AlbumPage {
        let data = try await request("artists/\(id)/albums", query: [
            "include_groups": "album,compilation", "limit": "10", "offset": String(offset)
        ])
        let page = try JSONDecoder().decode(SpotifyPage<Album>.self, from: data)
        return AlbumPage(albums: page.items.filter(\.isAllowed), nextOffset: nextOffset(page.next), total: page.total)
    }

    func savedAlbums(_ albums: [AlbumID]) async throws -> [Bool] {
        var result: [Bool] = []
        for start in stride(from: 0, to: albums.count, by: 40) {
            let batch = albums[start..<min(start + 40, albums.count)]
            let data = try await request("me/library/contains", query: ["uris": batch.map(\.uri).joined(separator: ",")])
            let flags = try JSONDecoder().decode([Bool].self, from: data)
            guard flags.count == batch.count else { throw SpotifyError.invalidResponse }
            result += flags
        }
        return result
    }

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
        return tracks.filter { ids.insert($0.occurrenceID).inserted }
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
    func playAlbum(_ album: AlbumID, device: String, start: AlbumPlaybackStart) async throws {
        guard !album.rawValue.isEmpty, start.trackIndex >= 0, start.positionMS >= 0 else { throw SpotifyError.invalidResponse }
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
        struct Offset: Encodable { let position: Int }
        struct Body: Encodable { let context_uri: String; let offset: Offset; let position_ms: Int }
        _ = try await request("me/player/play", method: "PUT", query: ["device_id": device],
                              body: JSONEncoder().encode(Body(context_uri: album.uri, offset: Offset(position: start.trackIndex), position_ms: start.positionMS)))
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
        let session = await auth.sessionVersion()
        // Skip/previous and starting an album may have succeeded before a connection was lost.
        // Replaying them could skip two tracks or restart the record.
        let canReplay = method != "POST" && !(path == "me/player/play" && body != nil)
        var url = URLComponents(string: "https://api.spotify.com/v1/\(path)")!
        if !query.isEmpty { url.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: url.url!)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var retries = 0
        var refreshed = false
        var rejectedAccess: String?
        var serverWait: TimeInterval = 0
        while true {
            try await checkSession(session)
            if quotaExceeded { throw SpotifyError.quotaExceeded }
            // All requests share Spotify's cooldown, including requests started while another waits.
            if let retryAfter {
                let remaining = retryAfter.timeIntervalSince(retry.now())
                if remaining > 0 {
                    guard serverWait + remaining <= retry.maximumServerWait else {
                        throw SpotifyError.rateLimited(seconds: Int(min(Double(Int.max / 2), ceil(remaining))))
                    }
                    serverWait += remaining
                    try await retry.wait(remaining)
                    continue
                }
            }
            let access: String
            do { access = try await auth.accessToken(rejectedToken: rejectedAccess) }
            catch {
                try await checkSession(session)
                guard NetworkRetry.isTransient(error), retries < retry.maxRetries else { throw error }
                try await retry.wait(retry.backoff(retries)); retries += 1
                continue
            }
            try await checkSession(session)
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let data: Data
            let response: HTTPURLResponse
            do { (data, response) = try await transport.data(for: request) }
            catch {
                try await checkSession(session)
                guard canReplay, NetworkRetry.isTransient(error), retries < retry.maxRetries else { throw error }
                try await retry.wait(retry.backoff(retries)); retries += 1
                continue
            }
            try await checkSession(session)
            if (200..<300).contains(response.statusCode) { return data }
            switch response.statusCode {
            case 401 where !refreshed: rejectedAccess = access; refreshed = true; continue
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
                let seconds = NetworkRetry.retryAfter(response, now: retry.now())
                let deadline = retry.now().addingTimeInterval(seconds)
                retryAfter = max(retryAfter ?? deadline, deadline)
                guard retries < retry.maxRetries else {
                    throw SpotifyError.rateLimited(seconds: Int(min(Double(Int.max / 2), ceil(seconds))))
                }
                retries += 1
                // 429 explicitly rejects the command; even skip/previous can be retried after cooldown.
                continue
            default:
                guard canReplay, NetworkRetry.isTransient(status: response.statusCode), retries < retry.maxRetries else {
                    throw SpotifyError.http(response.statusCode, "操作未完成，请重试。")
                }
                let delay = response.value(forHTTPHeaderField: "Retry-After") == nil
                    ? retry.backoff(retries) : NetworkRetry.retryAfter(response, now: retry.now())
                guard delay <= retry.maximumServerWait else { throw SpotifyError.http(response.statusCode, "Spotify 暂时繁忙。") }
                try await retry.wait(delay); retries += 1
            }
        }
    }

    private func checkSession(_ version: Int) async throws {
        try Task.checkCancellation()
        guard await auth.sessionVersion() == version else { throw CancellationError() }
    }
}
