import Foundation
import Security

public protocol CredentialStore: Sendable {
    func load() throws -> OAuthCredentials?
    func save(_ credentials: OAuthCredentials) throws
    func delete() throws
}

/// Owns the ChatGPT session: loads stored credentials, refreshes them (single-flight) and persists rotations.
public actor AuthManager: CodexCredentialSource {
    public typealias Refresher = @Sendable (String) async throws -> OAuthCredentials

    private let store: CredentialStore
    private let refresher: Refresher
    private let now: @Sendable () -> Date
    /// Refresh this long before expiry.
    private let leeway: TimeInterval = 300
    private var cached: OAuthCredentials?
    private var loaded = false
    private var refreshTask: Task<OAuthCredentials, Error>?

    public init(
        store: CredentialStore,
        refresher: @escaping Refresher = { try await CodexOAuth.refresh($0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.refresher = refresher
        self.now = now
    }

    public func credentials() throws -> OAuthCredentials? {
        if !loaded {
            cached = try store.load()
            loaded = true
        }
        return cached
    }

    public func signIn(_ credentials: OAuthCredentials) throws {
        try store.save(credentials)
        cached = credentials
        loaded = true
    }

    public func signOut() throws {
        refreshTask?.cancel()
        refreshTask = nil
        try store.delete()
        cached = nil
        loaded = true
    }

    public func currentAuth() async throws -> CodexAuth {
        guard let creds = try credentials() else { throw LLMError.notSignedIn }
        if creds.expiresAt.timeIntervalSince(now()) > leeway {
            return CodexAuth(accessToken: creds.accessToken, accountId: creds.accountId)
        }
        return try await refreshed(from: creds)
    }

    public func authAfterUnauthorized() async throws -> CodexAuth {
        guard let creds = try credentials() else { throw LLMError.notSignedIn }
        return try await refreshed(from: creds)
    }

    private func refreshed(from creds: OAuthCredentials) async throws -> CodexAuth {
        let task: Task<OAuthCredentials, Error>
        if let refreshTask {
            task = refreshTask
        } else {
            let refresher = self.refresher
            let token = creds.refreshToken
            task = Task { try await refresher(token) }
            refreshTask = task
        }
        do {
            var fresh = try await task.value
            if refreshTask == task {
                refreshTask = nil
                if fresh.email == nil { fresh.email = creds.email }
                try store.save(fresh)
                cached = fresh
            }
            let current = cached ?? fresh
            return CodexAuth(accessToken: current.accessToken, accountId: current.accountId)
        } catch {
            if refreshTask == task { refreshTask = nil }
            throw error
        }
    }
}

public final class KeychainCredentialStore: CredentialStore {
    let service: String
    let account: String

    public init(service: String = "dev.stas.tolk", account: String = "chatgpt") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() throws -> OAuthCredentials? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(OAuthCredentials.self, from: data)
    }

    public func save(_ credentials: OAuthCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(q as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: OAuthCredentials?
    public private(set) var saveCount = 0

    public init(_ value: OAuthCredentials? = nil) { self.value = value }

    public func load() throws -> OAuthCredentials? { lock.withLock { value } }
    public func save(_ credentials: OAuthCredentials) throws {
        lock.withLock {
            value = credentials
            saveCount += 1
        }
    }
    public func delete() throws { lock.withLock { value = nil } }
}

/// Development-only: reads Pi's existing openai-codex token read-only. Never refreshes or writes it.
public struct PiDevCredentialSource: CodexCredentialSource {
    public static let path = NSString(string: "~/.pi/agent/auth.json").expandingTildeInPath

    public init() {}

    public func currentAuth() async throws -> CodexAuth {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.path))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let entry = json["openai-codex"],
              let access = entry["access"]?.stringValue,
              let account = entry["accountId"]?.stringValue ?? CodexOAuth.accountID(fromJWT: access)
        else { throw LLMError.notSignedIn }
        return CodexAuth(accessToken: access, accountId: account)
    }

    public func authAfterUnauthorized() async throws -> CodexAuth {
        throw LLMError.unauthorized
    }
}
