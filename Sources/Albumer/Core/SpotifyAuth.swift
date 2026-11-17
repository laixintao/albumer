import Foundation

enum SpotifyOAuthConfiguration {
    // The Dashboard currently rejects portless HTTP loopback URLs, even though
    // the redirect URI documentation permits them. Register this exact URL.
    static let callbackPort: UInt16 = 8888
    static let redirectURI = "http://127.0.0.1:\(callbackPort)/callback"
}

actor SpotifyAuth {
    private let store: any TokenStore
    private let transport: any HTTPTransport
    private var token: StoredToken?
    private var refreshTask: Task<StoredToken, Error>?
    private var server: OAuthCallbackServer?
    private var generation = 0

    init(store: any TokenStore = KeychainTokenStore(), transport: any HTTPTransport = URLSessionTransport()) {
        self.store = store; self.transport = transport
    }
    func restore() throws -> Bool {
        token = try store.read()
        return token != nil
    }
    func sessionVersion() -> Int { generation }
    func accountIdentifier() -> String? { token?.accountID }
    func setAccountIdentifier(_ id: String) throws {
        guard var token else { throw SpotifyError.signedOut }
        token.accountID = id
        try store.write(token); self.token = token
    }
    func cacheIdentifier() -> String? {
        guard let token else { return nil }
        return token.accountID ?? "session-" + LocalStore.key(token.refreshToken)
    }
    func disconnect() async throws {
        generation += 1
        refreshTask?.cancel(); refreshTask = nil
        await server?.cancel(); server = nil
        token = nil
        try store.write(nil)
    }
    func cancelAuthorization() async { await server?.cancel() }

    func authorize(clientID: String, open: @Sendable (URL) async -> Void) async throws {
        guard clientID.count == 32, clientID.allSatisfy(\.isHexDigit) else { throw SpotifyError.invalidClientID }
        await server?.cancel()
        generation += 1
        let generation = generation
        let pkce = try PKCE()
        let server = OAuthCallbackServer(state: pkce.state)
        self.server = server
        do {
            _ = try await server.start(port: SpotifyOAuthConfiguration.callbackPort)
            let redirect = SpotifyOAuthConfiguration.redirectURI
            await open(pkce.authorizationURL(clientID: clientID, redirectURI: redirect))
            let code = try await server.waitForCode()
            let reply = try await Self.exchange([
                "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                "client_id": clientID, "code_verifier": pkce.verifier
            ], transport: transport)
            guard generation == self.generation else { throw CancellationError() }
            guard let refresh = reply.refreshToken else { throw SpotifyError.invalidResponse }
            let token = StoredToken(accessToken: reply.accessToken, refreshToken: refresh,
                                    expiresAt: Date().addingTimeInterval(reply.expiresIn), clientID: clientID)
            try store.write(token); self.token = token; self.server = nil
        } catch {
            await server.cancel()
            if generation == self.generation { self.server = nil }
            throw error
        }
    }

    func accessToken(rejectedToken: String? = nil) async throws -> String {
        guard let token else { throw SpotifyError.signedOut }
        if token.expiresAt.timeIntervalSinceNow > 60 && (rejectedToken == nil || rejectedToken != token.accessToken) {
            return token.accessToken
        }
        if let refreshTask {
            let generation = generation
            let refreshed = try await refreshTask.value
            guard generation == self.generation else { throw CancellationError() }
            return refreshed.accessToken
        }
        let transport = transport
        let generation = generation
        let task = Task<StoredToken, Error> {
            let reply = try await Self.exchange([
                "grant_type": "refresh_token", "refresh_token": token.refreshToken, "client_id": token.clientID
            ], transport: transport)
            return StoredToken(accessToken: reply.accessToken, refreshToken: reply.refreshToken ?? token.refreshToken,
                               expiresAt: Date().addingTimeInterval(reply.expiresIn), clientID: token.clientID, accountID: token.accountID)
        }
        refreshTask = task
        do {
            let renewed = try await task.value
            guard generation == self.generation else { throw CancellationError() }
            try store.write(renewed); self.token = renewed; refreshTask = nil
            return renewed.accessToken
        } catch {
            if generation == self.generation {
                refreshTask = nil
                if (error as? SpotifyError) == .signedOut { self.token = nil; try? store.write(nil) }
            }
            throw error
        }
    }

    private struct TokenReply: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
        }
    }
    private static func exchange(_ values: [String: String], transport: any HTTPTransport) async throws -> TokenReply {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.encode(values)
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 400 || response.statusCode == 401 { throw SpotifyError.signedOut }
            throw SpotifyError.http(response.statusCode, "无法完成授权，请稍后重试。")
        }
        return try JSONDecoder().decode(TokenReply.self, from: data)
    }
}

