import Foundation
import Security

struct StoredToken: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let clientID: String
    var accountID: String? = nil
}

protocol TokenStore: Sendable {
    func read() throws -> StoredToken?
    func write(_ token: StoredToken?) throws
}

struct KeychainTokenStore: TokenStore {
    private let service = "app.albumer.spotify"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "oauth"]
    }
    func read() throws -> StoredToken? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SpotifyError.keychain(status) }
        return try JSONDecoder().decode(StoredToken.self, from: data)
    }
    func write(_ token: StoredToken?) throws {
        guard let token else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SpotifyError.keychain(status) }
            return
        }
        let values = [kSecValueData as String: try JSONEncoder().encode(token)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var q = query.merging(values, uniquingKeysWith: { _, new in new })
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SpotifyError.keychain(status) }
    }
}

protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpotifyError.invalidResponse }
        return (data, http)
    }
}

