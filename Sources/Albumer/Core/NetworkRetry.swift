import Foundation

/// Bounded retries for temporary failures. The caller decides whether replaying a request is safe.
struct NetworkRetry: Sendable {
    var maxRetries = 3
    var maximumServerWait: TimeInterval = 15
    var now: @Sendable () -> Date = { .now }
    var wait: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }
    var backoff: @Sendable (Int) -> TimeInterval = { retry in
        min(8, 0.6 * pow(2, Double(retry))) * Double.random(in: 0.8...1.2)
    }

    static func isTransient(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                    .resourceUnavailable].contains(error.code)
        }
        switch error as? SpotifyError {
        case .http(let status, _): return isTransient(status: status)
        case .rateLimited: return true
        default: return false
        }
    }
    static func isTransient(status: Int) -> Bool { [408, 500, 502, 503, 504].contains(status) }

    static func retryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return 5 }
        if let seconds = Double(value), seconds.isFinite { return max(1, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(1, $0.timeIntervalSince(now)) } ?? 5
    }

    static func message(for error: Error) -> String {
        if case .rateLimited = error as? SpotifyError { return "Spotify 暂时繁忙，请稍后重试。" }
        if isTransient(error) { return "暂时无法连接 Spotify，请稍后重试。" }
        return error.localizedDescription
    }
}
