import XCTest
#if SWIFT_PACKAGE
@testable import AlbumerCore
#endif

private final class RetryTokens: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: StoredToken?
    init(expired: Bool = false) {
        token = StoredToken(accessToken: "access", refreshToken: "refresh",
                            expiresAt: Date().addingTimeInterval(expired ? -10 : 3600), clientID: "client")
    }
    func read() throws -> StoredToken? { lock.withLock { token } }
    func write(_ token: StoredToken?) throws { lock.withLock { self.token = token } }
}

private actor RetryHTTP: HTTPTransport {
    enum Reply: Sendable {
        case http(Int, String = "", [String: String] = [:])
        case failure(URLError.Code)
    }
    var replies: [Reply]
    var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw SpotifyError.invalidResponse }
        switch replies.removeFirst() {
        case .failure(let code): throw URLError(code)
        case .http(let code, let body, let headers):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!)
        }
    }
}

private final class RetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_000)
    private var sleeps: [TimeInterval] = []
    var now: Date { lock.withLock { instant } }
    var delays: [TimeInterval] { lock.withLock { sleeps } }
    func advance(_ seconds: TimeInterval) {
        lock.withLock { sleeps.append(seconds); instant.addTimeInterval(seconds) }
    }
    var policy: NetworkRetry {
        NetworkRetry(now: { self.now }, wait: { self.advance($0); await Task.yield() }, backoff: { 0.6 * pow(2, Double($0)) })
    }
}

private actor RetryPause {
    var started = false
    func sleep(_ seconds: TimeInterval) async throws {
        started = true
        try await Task.sleep(for: .seconds(30))
    }
}

final class NetworkRetryTests: XCTestCase, @unchecked Sendable {
    private func client(_ http: RetryHTTP, retry: NetworkRetry, expired: Bool = false) async throws -> (SpotifyClient, SpotifyAuth) {
        let auth = SpotifyAuth(store: RetryTokens(expired: expired), transport: http)
        _ = try await auth.restore()
        return (SpotifyClient(auth: auth, transport: http, retry: retry), auth)
    }

    func testSaveRetriesServerFailureAndLostResponseWithSameDesiredState() async throws {
        let clock = RetryClock()
        let http = RetryHTTP([.http(503), .failure(.networkConnectionLost), .http(204)])
        let (client, _) = try await client(http, retry: clock.policy)
        try await client.setSaved(AlbumID(rawValue: "record"), saved: true)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "PUT" && $0.url == requests[0].url })
        XCTAssertEqual(clock.delays, [0.6, 1.2])
    }
    func testRemoveAndReadsAlsoRetryTemporaryFailures() async throws {
        let clock = RetryClock()
        let http = RetryHTTP([.failure(.timedOut), .http(204), .http(502), .http(200, "{\"devices\":[]}")])
        let (client, _) = try await client(http, retry: clock.policy)
        try await client.setSaved(AlbumID(rawValue: "record"), saved: false)
        let devices = try await client.devices()
        XCTAssertTrue(devices.isEmpty)
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["DELETE", "DELETE", "GET", "GET"])
    }
    func testRetriesStopAfterThreeAndReturnFinalFailure() async throws {
        let clock = RetryClock()
        let http = RetryHTTP(Array(repeating: .http(503), count: 5))
        let (client, _) = try await client(http, retry: clock.policy)
        do { _ = try await client.devices(); XCTFail("Expected exhausted retries") }
        catch { guard case .http(503, _) = error as? SpotifyError else { return XCTFail("Wrong failure: \(error)") } }
        let count = await http.requests.count
        XCTAssertEqual(count, 4)
        XCTAssertEqual(clock.delays, [0.6, 1.2, 2.4])
    }
    func testPermissionMissingContentAndCertificateErrorsAreNotRetried() async throws {
        for reply in [RetryHTTP.Reply.http(403), .http(404), .failure(.secureConnectionFailed)] {
            let clock = RetryClock()
            let http = RetryHTTP([reply])
            let (client, _) = try await client(http, retry: clock.policy)
            do { _ = try await client.devices(); XCTFail("Expected permanent error") } catch {}
            let count = await http.requests.count
            XCTAssertEqual(count, 1)
            XCTAssertTrue(clock.delays.isEmpty)
        }
    }
    func testRateLimitWaitsThenRetriesAndUsesSharedCooldownForOtherRequests() async throws {
        let clock = RetryClock()
        var policy = clock.policy
        policy.maxRetries = 0
        let http = RetryHTTP([.http(429, "", ["Retry-After": "3"]), .http(200, "{\"devices\":[]}")])
        let (client, _) = try await client(http, retry: policy)
        do { _ = try await client.playback(); XCTFail("Expected rate limit") } catch {}
        await client.resetBackoff()
        _ = try await client.devices()
        XCTAssertEqual(clock.delays, [3], "New requests and manual retry must respect the existing cooldown")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }
    func testShortRateLimitAutomaticallyReplaysRejectedSkipOnlyOnce() async throws {
        let clock = RetryClock()
        let http = RetryHTTP([.http(429, "", ["Retry-After": "2"]), .http(204)])
        let (client, _) = try await client(http, retry: clock.policy)
        try await client.command(.next, device: "mac")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/v1/me/player/next" })
        XCTAssertEqual(clock.delays, [2])
    }
    func testAmbiguousSkipOrAlbumStartIsNeverRepeated() async throws {
        let clock = RetryClock()
        let http = RetryHTTP([.failure(.networkConnectionLost)])
        let (client, _) = try await client(http, retry: clock.policy)
        do { try await client.command(.next, device: "mac"); XCTFail("Expected lost response") } catch {}
        let count = await http.requests.count
        XCTAssertEqual(count, 1)
        let startHTTP = RetryHTTP([.http(204), .http(204), .http(204), .failure(.timedOut)])
        let (startClient, _) = try await self.client(startHTTP, retry: clock.policy)
        do { try await startClient.playAlbum(AlbumID(rawValue: "record"), device: "mac"); XCTFail("Expected timeout") } catch {}
        let starts = await startHTTP.requests.filter { $0.url?.path == "/v1/me/player/play" }
        XCTAssertEqual(starts.count, 1)
        XCTAssertTrue(clock.delays.isEmpty)
    }
    func testTokenRefreshTemporaryFailureRetriesBeforeSendingSave() async throws {
        let clock = RetryClock()
        let http = RetryHTTP([.http(503), .http(200, "{\"access_token\":\"new-access\",\"expires_in\":3600}"), .http(204)])
        let (client, _) = try await client(http, retry: clock.policy, expired: true)
        try await client.setSaved(AlbumID(rawValue: "record"), saved: true)
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/token", "/api/token", "/v1/me/library"])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
        XCTAssertEqual(clock.delays, [0.6])
    }
    func testCancellationDuringBackoffStopsFurtherRequests() async throws {
        let pause = RetryPause()
        var policy = NetworkRetry()
        policy.wait = { try await pause.sleep($0) }
        let http = RetryHTTP([.http(503), .http(204)])
        let (client, _) = try await client(http, retry: policy)
        let task = Task { try await client.setSaved(AlbumID(rawValue: "record"), saved: true) }
        for _ in 0..<100 {
            if await pause.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let count = await http.requests.count
        XCTAssertEqual(count, 1)
    }
    func testDisconnectDuringBackoffNeverResendsOldAccountMutation() async throws {
        let http = RetryHTTP([.http(503), .http(204)])
        let auth = SpotifyAuth(store: RetryTokens(), transport: http)
        _ = try await auth.restore()
        var policy = NetworkRetry()
        policy.wait = { _ in try await auth.disconnect() }
        let client = SpotifyClient(auth: auth, transport: http, retry: policy)
        do { try await client.setSaved(AlbumID(rawValue: "record"), saved: true); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await http.requests.count
        XCTAssertEqual(count, 1)
    }
    func testRetryAfterHTTPDateAndLongCooldown() async throws {
        let clock = RetryClock()
        let http = RetryHTTP([.http(429, "", ["Retry-After": "Thu, 01 Jan 1970 00:16:43 GMT"]), .http(204)])
        let (client, _) = try await client(http, retry: clock.policy)
        _ = try await client.playback()
        XCTAssertEqual(clock.delays, [3])
        let longHTTP = RetryHTTP([.http(429, "", ["Retry-After": "60"])])
        let (longClient, _) = try await self.client(longHTTP, retry: clock.policy)
        do { _ = try await longClient.devices(); XCTFail("Expected deferred request") }
        catch { XCTAssertEqual(error as? SpotifyError, .rateLimited(seconds: 60)) }
        let count = await longHTTP.requests.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(clock.delays, [3], "Do not leave the UI spinning through long server cooldowns")
    }
}
