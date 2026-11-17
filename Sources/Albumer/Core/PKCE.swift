import Foundation
import CryptoKit
import Security

struct PKCE: Sendable {
    let verifier: String
    let state: String
    init(verifier: String? = nil, state: String? = nil) throws {
        self.verifier = try verifier ?? Self.randomString()
        self.state = try state ?? Self.randomString()
    }
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }
    static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw SpotifyError.keychain(result) }
        return Data(bytes).base64URL
    }
    func authorizationURL(clientID: String, redirectURI: String) -> URL {
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: "user-library-read user-library-modify user-read-playback-state user-modify-playback-state")
        ]
        return c.url!
    }
    static func callbackCode(target: String, expectedState: String) throws -> String {
        guard let c = URLComponents(string: target), c.path == "/callback" else { throw SpotifyError.invalidResponse }
        let params = c.queryItems ?? []
        guard params.filter({ $0.name == "state" }).count == 1,
              params.first(where: { $0.name == "state" })?.value == expectedState else { throw SpotifyError.invalidState }
        if params.contains(where: { $0.name == "error" }) { throw SpotifyError.authorizationCancelled }
        guard params.filter({ $0.name == "code" }).count == 1,
              let code = params.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw SpotifyError.invalidResponse }
        return code
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum FormEncoding {
    static func encode(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
}

