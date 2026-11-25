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
    func testArtistPortraitLoadsFromArtistEndpointAndUsesSmallImage() async throws {
        let http = MockHTTP([.init(body: """
        {"id":"artist1","name":"An artist","images":[
          {"url":"https://images.example/large.jpg","width":640,"height":640},
          {"url":"https://images.example/small.jpg","width":160,"height":160}
        ]}
        """)])
        let (client, _, _) = try await authorized(http)
        let artist = try await client.artist("artist1")
        XCTAssertEqual(artist?.id, "artist1")
        XCTAssertEqual(artist?.portrait?.absoluteString, "https://images.example/small.jpg")
        let requests = await http.recorded()
        XCTAssertEqual(requests.first?.url?.path, "/v1/artists/artist1")
    }
    func testDirectAlbumLookupSupportsCurrentlyPlayingSingleWithoutAddingItToLibrary() async throws {
        let http = MockHTTP([.init(body: albumJSON("playing", type: "single"))])
        let (client, _, _) = try await authorized(http)
        let record = try await client.album(AlbumID(rawValue: "playing"))
        XCTAssertEqual(record.id, "playing")
        XCTAssertEqual(record.albumType, "single")
        let requests = await http.recorded()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertEqual(requests.first?.url?.path, "/v1/albums/playing")
    }
    func testArtistAlbumsUsesCurrentPageLimitFiltersSinglesAndRetainsPagination() async throws {
        let http = MockHTTP([.init(body: """
        {"items":[\(albumJSON("record")),\(albumJSON("single", type: "single"))],
         "next":"https://api.spotify.com/v1/artists/artist1/albums?offset=20","offset":10,"total":30}
        """)])
        let (client, _, _) = try await authorized(http)
        let page = try await client.artistAlbums("artist1", offset: 10)
        XCTAssertEqual(page.albums.map(\.id), ["record"])
        XCTAssertEqual(page.nextOffset, 20)
        let requests = await http.recorded()
        let url = try XCTUnwrap(requests.first?.url)
        XCTAssertEqual(url.path, "/v1/artists/artist1/albums")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "limit", value: "10")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "offset", value: "10")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "include_groups", value: "album,compilation")))
    }
    func testBatchSavedAlbumsSplitsAtFortyAndPreservesOrder() async throws {
        let flags = (0..<40).map { $0.isMultiple(of: 2) }
        let body = String(data: try JSONEncoder().encode(flags), encoding: .utf8)!
        let http = MockHTTP([.init(body: body), .init(body: "[true,false]")])
        let (client, _, _) = try await authorized(http)
        let ids = (0..<42).map { AlbumID(rawValue: "album-\($0)") }
        let actual = try await client.savedAlbums(ids)
        XCTAssertEqual(actual, flags + [true, false])
        let requests = await http.recorded()
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/v1/me/library/contains")
            let uris = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "uris" }?.value
            XCTAssertEqual(uris?.components(separatedBy: ","), Array(ids.dropFirst(index * 40).prefix(40)).map(\.uri))
        }
        let empty = try await client.savedAlbums([])
        XCTAssertTrue(empty.isEmpty)
        let count = await http.recorded().count
        XCTAssertEqual(count, 2)
    }
    func testBatchSavedAlbumsRejectsMissingFlagsInsteadOfAssumingUnsaved() async throws {
        let http = MockHTTP([.init(body: "[true]")])
        let (client, _, _) = try await authorized(http)
        do {
            _ = try await client.savedAlbums([AlbumID(rawValue: "one"), AlbumID(rawValue: "two")])
            XCTFail("Incomplete flags must not classify unknown albums as unsaved")
        } catch { XCTAssertEqual(error as? SpotifyError, .invalidResponse) }
    }
    func testArtistWithoutPortraitOrLegacyIdentifierStillDecodes() throws {
        let legacy = try JSONDecoder().decode(Artist.self, from: Data("{\"name\":\"An artist\"}".utf8))
        XCTAssertNil(legacy.id)
        XCTAssertNil(legacy.portrait)
        let noPhoto = try JSONDecoder().decode(Artist.self, from: Data("{\"name\":\"An artist\",\"id\":\"artist1\",\"images\":[]}".utf8))
        XCTAssertNil(noPhoto.portrait)
    }
    func testPlaybackNullsAndUnknownContentAreSafe() throws {
        let state = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data("""
        {"is_playing":true,"progress_ms":null,"context":null,"item":{"type":"episode","name":"Podcast","artists":[],"duration_ms":60000},"actions":{"disallows":{"skipping_next":true}}}
        """.utf8))
        XCTAssertNil(state.item); XCTAssertEqual(state.position(), 0); XCTAssertFalse(state.allows("skipping_next"))
        let actions = try JSONDecoder().decode(PlaybackActions.self, from: Data("{\"seeking\":true}".utf8))
        XCTAssertEqual(actions.disallows["seeking"], true)
    }
    func testIncompletePlaybackAlbumPreservesTrackAndAlbumReference() throws {
        let state = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data("""
        {"is_playing":true,"progress_ms":42000,"context":null,"item":{
          "type":"track","id":"song1","name":"Playing song","artists":[{"name":"An artist"}],
          "duration_ms":180000,"track_number":2,"disc_number":1,
          "album":{"id":"album1","name":"A record","images":[]}
        }}
        """.utf8))
        XCTAssertEqual(state.item?.id, "song1")
        XCTAssertEqual(state.item?.name, "Playing song")
        XCTAssertNil(state.item?.album)
        XCTAssertEqual(state.item?.albumID, AlbumID(rawValue: "album1"))
        XCTAssertEqual(state.position(at: state.receivedAt), 42)
    }
    func testPlaybackAlbumCanBeIdentifiedByURIWithoutFullMetadata() throws {
        let state = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data("""
        {"is_playing":true,"item":{"type":"track","name":"Song","duration_ms":180000,
          "album":{"uri":"spotify:album:album1"}}}
        """.utf8))
        XCTAssertEqual(state.item?.albumID, AlbumID(rawValue: "album1"))
        XCTAssertNil(PlaybackContext(type: "playlist", uri: "spotify:playlist:list1").albumID)
        XCTAssertNil(PlaybackContext(type: "album", uri: "spotify:album:").albumID)
    }
    func testPlaybackKeepsCoverEvenWhenAlbumMetadataIsIncomplete() throws {
        let state = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data("""
        {"is_playing":true,"item":{"id":"song","name":"Song","duration_ms":180000,
          "album":{"id":"album1","images":[
            {"url":"https://example.test/small.jpg","width":64},
            {"url":"https://example.test/cover.jpg","width":640}]}}}
        """.utf8))
        XCTAssertNil(state.item?.album)
        XCTAssertEqual(state.item?.albumID, AlbumID(rawValue: "album1"))
        XCTAssertEqual(state.item?.artwork?.absoluteString, "https://example.test/cover.jpg")
    }
    func testInvalidPlaybackImagesDoNotDiscardAlbumIdentity() throws {
        let state = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data("""
        {"item":{"name":"Song","duration_ms":180000,"album":{"id":"album1","images":"unavailable"}}}
        """.utf8))
        XCTAssertEqual(state.item?.albumID, AlbumID(rawValue: "album1"))
        XCTAssertNil(state.item?.artwork)
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
    func testRepeatedRecordingOnAnotherDiscKeepsItsAlbumPlaybackOffset() async throws {
        let first = """
        {"id":"repeated","name":"Song","artists":[],"duration_ms":120000,"disc_number":1,"track_number":1}
        """
        let repeated = """
        {"id":"repeated","name":"Song","artists":[],"duration_ms":120000,"disc_number":2,"track_number":1}
        """
        let last = """
        {"id":"last","name":"Last","artists":[],"duration_ms":180000,"disc_number":2,"track_number":2}
        """
        let http = MockHTTP([
            .init(body: "{\"items\":[\(first),\(repeated),\(last)],\"next\":null,\"offset\":0,\"total\":3}")
        ])
        let (client, _, _) = try await authorized(http)
        let tracks = try await client.albumTracks(AlbumID(rawValue: "record"))
        XCTAssertEqual(tracks.map(\.id), ["repeated", "repeated", "last"])
        XCTAssertEqual(Set(tracks.map(\.occurrenceID)).count, 3)
        let position = AlbumPlaybackPosition(trackID: "last", linkedFromID: nil, discNumber: 2, trackNumber: 2, positionMS: 42000)
        XCTAssertEqual(position.start(in: tracks), AlbumPlaybackStart(trackIndex: 2, positionMS: 42000))
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
    func testAlbumStartSendsSelectedTrackAndResumePositionInAlbumContext() async throws {
        let http = MockHTTP([.init(status: 204), .init(status: 204), .init(status: 204), .init(status: 204)])
        let (client, _, _) = try await authorized(http)
        try await client.playAlbum(AlbumID(rawValue: "multidisc"), device: "mac",
                                   start: AlbumPlaybackStart(trackIndex: 12, positionMS: 42000))
        let requests = await http.recorded()
        let body = try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["context_uri"] as? String, "spotify:album:multidisc")
        XCTAssertEqual((body["offset"] as? [String: Int])?["position"], 12)
        XCTAssertEqual(body["position_ms"] as? Int, 42000)
        XCTAssertNil(body["uris"], "The remaining album should keep playing in order")
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

