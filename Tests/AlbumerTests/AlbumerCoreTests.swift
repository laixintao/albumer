import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

private final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: StoredToken?
    init(_ token: StoredToken?) { self.token = token }
    func read() throws -> StoredToken? { lock.withLock { token } }
    func write(_ token: StoredToken?) throws { lock.withLock { self.token = token } }
}

private actor MockHTTP: HTTPTransport {
    struct Reply: Sendable {
        var status: Int = 200
        var body: String = ""
        var headers: [String: String] = [:]
    }
    private var replies: [Reply]
    private var requests: [URLRequest] = []
    private let delay: Duration
    init(_ replies: [Reply], delay: Duration = .zero) { self.replies = replies; self.delay = delay }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw SpotifyError.invalidResponse }
        let reply = replies.removeFirst()
        if delay != .zero { try await Task.sleep(for: delay) }
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }
    func recorded() -> [URLRequest] { requests }
}

final class AlbumerCoreTests: XCTestCase, @unchecked Sendable {
    private func albumJSON(_ id: String = "album1", type: String = "album") -> String {
        """
        {"id":"\(id)","name":"A record","artists":[{"name":"An artist"}],"album_type":"\(type)","images":[],"release_date":"2007","total_tracks":10}
        """
    }
    private func authorized(_ http: MockHTTP, expired: Bool = false) async throws -> (SpotifyClient, SpotifyAuth, MemoryTokenStore) {
        let store = MemoryTokenStore(StoredToken(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: Date().addingTimeInterval(expired ? -5 : 3600), clientID: String(repeating: "a", count: 32)))
        let auth = SpotifyAuth(store: store, transport: http)
        _ = try await auth.restore()
        return (SpotifyClient(auth: auth, transport: http), auth, store)
    }

    func testPKCERFC7636Vector() throws {
        let pkce = try PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "state")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let a = try PKCE(); let b = try PKCE()
        XCTAssertEqual(a.verifier.count, 43)
        XCTAssertNotEqual(a.verifier, b.verifier)
        XCTAssertNotEqual(a.state, a.verifier)
    }
    func testAuthorizationUsesPKCEAndMinimalScopes() throws {
        let pkce = try PKCE(verifier: "verifier", state: "state")
        let components = URLComponents(url: pkce.authorizationURL(clientID: "client", redirectURI: "http://127.0.0.1:4567/callback"), resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:4567/callback")
        XCTAssertNil(items["client_secret"])
        XCTAssertEqual(Set(items["scope"]!.split(separator: " ")), Set(["user-library-read", "user-library-modify", "user-read-playback-state", "user-modify-playback-state"]))
    }
    func testCallbackRejectsForgedOrDuplicateStateAndCancellation() throws {
        XCTAssertEqual(try PKCE.callbackCode(target: "/callback?code=abc%2B123&state=good", expectedState: "good"), "abc+123")
        XCTAssertThrowsError(try PKCE.callbackCode(target: "/callback?code=abc&state=bad", expectedState: "good")) { XCTAssertEqual($0 as? SpotifyError, .invalidState) }
        XCTAssertThrowsError(try PKCE.callbackCode(target: "/callback?code=abc&state=good&state=good", expectedState: "good"))
        XCTAssertThrowsError(try PKCE.callbackCode(target: "/callback?error=access_denied&state=good", expectedState: "good")) { XCTAssertEqual($0 as? SpotifyError, .authorizationCancelled) }
        XCTAssertThrowsError(try PKCE.callbackCode(target: "/elsewhere?code=abc&state=good", expectedState: "good"))
    }
    func testFormEncodingPreservesReservedCharacters() {
        let encoded = String(data: FormEncoding.encode(["code": "a+b&c= d"]), encoding: .utf8)
        XCTAssertEqual(encoded, "code=a%2Bb%26c%3D%20d")
    }
    func testAlbumDecodingDoesNotRequireRemovedSpotifyFields() throws {
        let album = try JSONDecoder().decode(Album.self, from: Data(albumJSON().utf8))
        XCTAssertTrue(album.isAllowed); XCTAssertEqual(album.year, "2007"); XCTAssertNil(album.artwork)
        let single = try JSONDecoder().decode(Album.self, from: Data(albumJSON(type: "single").utf8))
        XCTAssertFalse(single.isAllowed)
        let compilation = try JSONDecoder().decode(Album.self, from: Data(albumJSON(type: "compilation").utf8))
        XCTAssertTrue(compilation.isAllowed)
    }
    func testPlaybackNullsAndUnknownContentAreSafe() throws {
        let state = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data("""
        {"is_playing":true,"progress_ms":null,"context":null,"item":{"type":"episode","name":"Podcast"},"actions":{"disallows":{"skipping_next":true}}}
        """.utf8))
        XCTAssertNil(state.item); XCTAssertEqual(state.position(), 0); XCTAssertFalse(state.allows("skipping_next"))
        let actions = try JSONDecoder().decode(PlaybackActions.self, from: Data("{\"seeking\":true}".utf8))
        XCTAssertEqual(actions.disallows["seeking"], true)
    }
    func testProgressUsesElapsedTimeAndClampsAtDuration() {
        var state = PlaybackSnapshot(isPlaying: true, progressMS: 5000, item: PlaybackTrack(id: "song", name: "song", artists: [], durationMS: 10000, trackNumber: 1, discNumber: 2, album: nil))
        state.receivedAt = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(state.position(at: Date(timeIntervalSince1970: 103)), 8)
        XCTAssertEqual(state.position(at: Date(timeIntervalSince1970: 120)), 10)
        state.isPlaying = false
        XCTAssertEqual(state.position(at: Date(timeIntervalSince1970: 120)), 5)
    }
    func testSearchFiltersSinglesWithoutLosingPagination() async throws {
        let http = MockHTTP([.init(body: """
        {"albums":{"items":[\(albumJSON(type: "single"))],"next":"https://api.spotify.com/v1/search?offset=10","offset":0,"total":30}}
        """)])
        let (client, _, _) = try await authorized(http)
        let page = try await client.searchAlbums(query: "artist & album", offset: 0)
        XCTAssertTrue(page.albums.isEmpty); XCTAssertEqual(page.nextOffset, 10)
        let request = await http.recorded()[0]
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first(where: { $0.name == "type" })?.value, "album")
        XCTAssertEqual(query.first(where: { $0.name == "limit" })?.value, "10")
        XCTAssertEqual(query.first(where: { $0.name == "q" })?.value, "artist & album")
    }
    func testLibraryUses2026URIEndpoint() async throws {
        let http = MockHTTP([.init(), .init(), .init(body: "[true]")])
        let (client, _, _) = try await authorized(http)
        let album = AlbumID(rawValue: "abc")
        try await client.setSaved(album, saved: true)
        try await client.setSaved(album, saved: false)
        let saved = try await client.isSaved(album)
        XCTAssertTrue(saved)
        let requests = await http.recorded()
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "DELETE", "GET"])
        XCTAssertEqual(requests[0].url?.path, "/v1/me/library")
        XCTAssertEqual(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "spotify:album:abc")
    }
    func testSavedAlbumsMatchLibraryAlbumsAndKeepPagination() async throws {
        let http = MockHTTP([.init(body: """
        {"items":[{"album":\(albumJSON("first"))},{"album":\(albumJSON("single", type: "single"))},{"album":\(albumJSON("third", type: "compilation"))}],"next":"https://api.spotify.com/v1/me/albums?offset=20&limit=20","offset":0,"total":37}
        """)])
        let (client, _, _) = try await authorized(http)
        let page = try await client.savedAlbums(offset: 0)
        XCTAssertEqual(page.albums.map(\.id), ["first", "third"])
        XCTAssertEqual(page.nextOffset, 20)
        XCTAssertEqual(page.total, 37)
        let requests = await http.recorded()
        XCTAssertEqual(requests.first?.url?.path, "/v1/me/albums")
    }
    func testAlbumTrackListLoadsAllDiscsAndDeduplicatesOverlappingPages() async throws {
        let first = """
        {"id":"disc-one","name":"Opening","artists":[],"duration_ms":120000,"disc_number":1,"track_number":1}
        """
        let second = """
        {"id":"disc-two","name":"Second disc","artists":[],"duration_ms":180000,"disc_number":2,"track_number":1}
        """
        let http = MockHTTP([
            .init(body: "{\"items\":[\(first)],\"next\":\"https://api.spotify.com/v1/albums/record/tracks?offset=50\",\"offset\":0,\"total\":2}"),
            .init(body: "{\"items\":[\(first),\(second)],\"next\":null,\"offset\":50,\"total\":2}")
        ])
        let (client, _, _) = try await authorized(http)
        let tracks = try await client.albumTracks(AlbumID(rawValue: "record"))
        XCTAssertEqual(tracks.map(\.id), ["disc-one", "disc-two"])
        XCTAssertEqual(tracks.map(\.discNumber), [1, 2])
        let requests = await http.recorded()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == "/v1/albums/record/tracks" })
    }
    func testIdlePlayback204() async throws {
        let http = MockHTTP([.init(status: 204)])
        let (client, _, _) = try await authorized(http)
        let state = try await client.playback()
        XCTAssertNil(state)
    }
    func test401RefreshesOnceAndKeepsOriginalRefreshToken() async throws {
        let http = MockHTTP([.init(status: 401), .init(body: "{\"access_token\":\"renewed\",\"expires_in\":3600}"), .init(status: 204)])
        let (client, _, store) = try await authorized(http)
        _ = try await client.playback()
        let requests = await http.recorded()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
        XCTAssertEqual(try store.read()?.refreshToken, "old-refresh")
    }
    func testConcurrentRefreshIsSingleFlight() async throws {
        let http = MockHTTP([.init(body: "{\"access_token\":\"renewed\",\"expires_in\":3600}")], delay: .milliseconds(40))
        let (_, auth, _) = try await authorized(http, expired: true)
        async let first = auth.accessToken()
        async let second = auth.accessToken()
        let values = try await [first, second]
        XCTAssertEqual(values, ["renewed", "renewed"])
        let requests = await http.recorded()
        XCTAssertEqual(requests.count, 1)
    }
    func testDisconnectDoesNotResurrectInFlightRefresh() async throws {
        let http = MockHTTP([.init(body: "{\"access_token\":\"renewed\",\"expires_in\":3600}")], delay: .milliseconds(80))
        let (_, auth, store) = try await authorized(http, expired: true)
        let task = Task { try await auth.accessToken() }
        try await Task.sleep(for: .milliseconds(10))
        try await auth.disconnect()
        _ = try? await task.value
        XCTAssertNil(try store.read())
    }
    func testQuotaStopsFurtherRequestsUntilExplicitRetry() async throws {
        let http = MockHTTP([.init(status: 429, body: "{\"error\":{\"reason\":\"QUOTA_EXCEEDED\"}}"), .init(status: 204)])
        let (client, _, _) = try await authorized(http)
        for _ in 0..<2 {
            do { _ = try await client.playback(); XCTFail("Expected quota error") }
            catch { XCTAssertEqual(error as? SpotifyError, .quotaExceeded) }
        }
        var requests = await http.recorded()
        XCTAssertEqual(requests.count, 1)
        await client.resetBackoff(); _ = try await client.playback()
        requests = await http.recorded(); XCTAssertEqual(requests.count, 2)
    }
    func testRetryAfterBlocksImmediateRequests() async throws {
        let http = MockHTTP([.init(status: 429, headers: ["Retry-After": "60"])])
        let (client, _, _) = try await authorized(http)
        for _ in 0..<2 {
            do { _ = try await client.devices(); XCTFail("Expected rate limit") }
            catch { guard case .rateLimited(let seconds) = error as? SpotifyError else { return XCTFail("Wrong error") }; XCTAssertGreaterThan(seconds, 0) }
            await client.resetBackoff() // Manual retry must not bypass Retry-After.
        }
        let requests = await http.recorded(); XCTAssertEqual(requests.count, 1)
    }
    func testAlbumStartUsesWholeContextAfterSettingsAreConfirmed() async throws {
        let http = MockHTTP([.init(status: 204), .init(status: 204), .init(body: "{\"is_playing\":false,\"shuffle_state\":false,\"repeat_state\":\"off\"}"), .init(status: 204)])
        let (client, _, _) = try await authorized(http)
        try await client.playAlbum(AlbumID(rawValue: "multidisc"), device: "mac")
        let requests = await http.recorded()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/v1/me/player/shuffle", "/v1/me/player/repeat", "/v1/me/player", "/v1/me/player/play"])
        let body = try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["context_uri"] as? String, "spotify:album:multidisc")
        XCTAssertEqual((body["offset"] as? [String: Int])?["position"], 0)
        XCTAssertEqual(body["position_ms"] as? Int, 0)
        XCTAssertNil(body["uris"])
    }
    func testDeviceForbiddenAndNotFoundAreActionable() async throws {
        let http = MockHTTP([.init(status: 403), .init(status: 404)])
        let (client, _, _) = try await authorized(http)
        do { _ = try await client.playback(); XCTFail() } catch { XCTAssertEqual(error as? SpotifyError, .restricted) }
        do { _ = try await client.playback(); XCTFail() } catch { XCTAssertEqual(error as? SpotifyError, .noDevice) }
    }
    func testIdleDeviceCanStartFirstAlbum() async throws {
        let http = MockHTTP([.init(status: 204), .init(status: 204), .init(status: 204), .init(status: 204)])
        let (client, _, _) = try await authorized(http)
        try await client.playAlbum(AlbumID(rawValue: "first-album"), device: "mac")
        let requests = await http.recorded()
        XCTAssertEqual(requests.last?.url?.path, "/v1/me/player/play")
    }
    func testUnavailableContentDoesNotPretendDeviceIsMissing() async throws {
        let http = MockHTTP([.init(status: 404)])
        let (client, _, _) = try await authorized(http)
        do { _ = try await client.isSaved(AlbumID(rawValue: "removed")); XCTFail() }
        catch { XCTAssertEqual(error as? SpotifyError, .http(404, "内容已不可用。")) }
    }
    func testAlbumTransactionStopsWhenAccountDisconnects() async throws {
        let http = MockHTTP([.init(status: 204)], delay: .milliseconds(80))
        let (client, auth, _) = try await authorized(http)
        let task = Task { try await client.playAlbum(AlbumID(rawValue: "album"), device: "mac") }
        try await Task.sleep(for: .milliseconds(10))
        try await auth.disconnect()
        do { try await task.value; XCTFail("An old album command must not continue in a new session") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await http.recorded()
        XCTAssertEqual(requests.count, 1)
    }
    func testLocalOAuthServerAcceptsOnlyCallbackAndShutsDown() async throws {
        let server = OAuthCallbackServer(state: "secure")
        let port = try await server.start()
        let base = "http://127.0.0.1:\(port)"
        let (_, wrong) = try await URLSession.shared.data(from: URL(string: base + "/favicon.ico")!)
        XCTAssertEqual((wrong as? HTTPURLResponse)?.statusCode, 404)
        let (_, correct) = try await URLSession.shared.data(from: URL(string: base + "/callback?state=secure&code=code123")!)
        XCTAssertEqual((correct as? HTTPURLResponse)?.statusCode, 200)
        let code = try await server.waitForCode()
        XCTAssertEqual(code, "code123")
    }
    func testLocalOAuthCancellationCompletesWaiter() async throws {
        let server = OAuthCallbackServer(state: "secure")
        _ = try await server.start()
        await server.cancel()
        do { _ = try await server.waitForCode(); XCTFail() }
        catch { XCTAssertEqual(error as? SpotifyError, .authorizationCancelled) }
    }

    func testAuthorizationUsesRegisteredPortAndMatchingTokenRedirect() async throws {
        let store = MemoryTokenStore(nil)
        let http = MockHTTP([.init(body: """
        {"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}
        """)])
        let auth = SpotifyAuth(store: store, transport: http)
        try await auth.authorize(clientID: String(repeating: "a", count: 32)) { url in
            do {
                let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                let redirect = try XCTUnwrap(items.first(where: { $0.name == "redirect_uri" })?.value)
                XCTAssertEqual(redirect, "http://127.0.0.1:8888/callback")
                let state = try XCTUnwrap(items.first(where: { $0.name == "state" })?.value)
                var callback = try XCTUnwrap(URLComponents(string: redirect))
                callback.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "test-code")]
                let (_, response) = try await URLSession.shared.data(from: XCTUnwrap(callback.url))
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            } catch {
                XCTFail("Local authorization callback failed: \(error)")
                await auth.cancelAuthorization()
            }
        }
        let requests = await http.recorded()
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(String(data: XCTUnwrap(requests.first?.httpBody), encoding: .utf8))
        let fields = try XCTUnwrap(URLComponents(string: "?" + body)?.queryItems)
        XCTAssertEqual(fields.first(where: { $0.name == "redirect_uri" })?.value, "http://127.0.0.1:8888/callback")
        XCTAssertEqual(fields.first(where: { $0.name == "code" })?.value, "test-code")
        XCTAssertEqual(try store.read()?.accessToken, "new-access")
    }

    func testOccupiedCallbackPortFailsInsteadOfChoosingDifferentRedirect() async throws {
        let owner = OAuthCallbackServer(state: "owner")
        let port = try await owner.start()
        let contender = OAuthCallbackServer(state: "contender")
        do {
            _ = try await contender.start(port: port)
            XCTFail("An occupied callback port must not fall back to a different redirect URI")
        } catch {
            XCTAssertEqual(error as? SpotifyError, .callbackPortUnavailable(port))
        }
        await contender.cancel()
        await owner.cancel()
    }
}

