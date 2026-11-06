import CryptoKit
import Foundation

/// Stored ChatGPT OAuth credentials.
public struct OAuthCredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var accountId: String
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, accountId: String, email: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountId = accountId
        self.email = email
    }
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func generate() -> PKCE {
        PKCE(verifier: base64URL(randomBytes(32)))
    }

    static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The ChatGPT ("Codex") OAuth client used by the Codex CLI.
public enum CodexOAuth {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let callbackPort: UInt16 = 1455
    public static let callbackPath = "/auth/callback"
    public static let redirectURI = "http://localhost:1455/auth/callback"
    static let scope = "openid profile email offline_access"
    static let jwtClaim = "https://api.openai.com/auth"

    public static func newState() -> String {
        PKCE.randomBytes(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func authorizationURL(pkce: PKCE, state: String) -> URL {
        var c = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "originator", value: "tolk"),
        ]
        return c.url!
    }

    /// Parses a pasted redirect URL (or `code#state`, or a bare code).
    public static func parseAuthorizationInput(_ input: String) -> (code: String?, state: String?) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return (nil, nil) }
        if let c = URLComponents(string: value), c.scheme != nil {
            let items = c.queryItems ?? []
            return (items.first { $0.name == "code" }?.value, items.first { $0.name == "state" }?.value)
        }
        if value.contains("#") {
            let parts = value.split(separator: "#", maxSplits: 1).map(String.init)
            return (parts.first, parts.count > 1 ? parts[1] : nil)
        }
        if value.contains("code=") {
            let items = URLComponents(string: "?" + value)?.queryItems ?? []
            return (items.first { $0.name == "code" }?.value, items.first { $0.name == "state" }?.value)
        }
        return (value, nil)
    }

    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }

    public static func exchangeCode(_ code: String, verifier: String, session: URLSession = .shared) async throws -> OAuthCredentials {
        try await tokenRequest([
            ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
            ("code_verifier", verifier), ("redirect_uri", redirectURI),
        ], session: session)
    }

    public static func refresh(_ refreshToken: String, session: URLSession = .shared) async throws -> OAuthCredentials {
        try await tokenRequest([
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID),
        ], session: session)
    }

    static func tokenRequest(_ fields: [(String, String)], session: URLSession) async throws -> OAuthCredentials {
        var r = URLRequest(url: tokenURL)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = formBody(fields)
        let (data, response) = try await session.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 400 || status == 401 { throw LLMError.unauthorized }
            throw LLMError.http(status: status, message: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try parseTokenResponse(data)
    }

    static func parseTokenResponse(_ data: Data, now: Date = Date()) throws -> OAuthCredentials {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let access = json["access_token"]?.stringValue,
              let refresh = json["refresh_token"]?.stringValue,
              let expiresIn = json["expires_in"]?.numberValue
        else { throw LLMError.invalidResponse("token response missing fields") }
        guard let accountId = accountID(fromJWT: access) else {
            throw LLMError.invalidResponse("token has no ChatGPT account id")
        }
        let email = json["id_token"]?.stringValue.flatMap { jwtPayload($0)?["email"]?.stringValue }
        return OAuthCredentials(
            accessToken: access, refreshToken: refresh,
            expiresAt: now.addingTimeInterval(expiresIn), accountId: accountId, email: email
        )
    }

    static func jwtPayload(_ token: String) -> JSONValue? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func accountID(fromJWT token: String) -> String? {
        guard let id = jwtPayload(token)?[jwtClaim]?["chatgpt_account_id"]?.stringValue, !id.isEmpty else { return nil }
        return id
    }
}
