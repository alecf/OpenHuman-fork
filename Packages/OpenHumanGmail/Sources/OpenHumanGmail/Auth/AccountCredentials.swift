import Foundation
import OpenHumanCore
import Synchronization

public final class AccountCredentials: Sendable {
    public let client: OAuthClientConfig
    private let store: any TokenStore
    private let transport: any HTTPTransport
    private let clock: any OHClock
    private let minimumValidity: Duration
    private let retryWaits: [Duration]
    private let onEvent: (@Sendable (TokenEvent) -> Void)?
    private let knownClients: (@Sendable () -> [OAuthClientConfig])?
    private let managers = Mutex<[String: Entry]>([:])

    private struct Entry: Sendable {
        let manager: TokenManager
        let clientID: String
    }

    public convenience init(store: any TokenStore, client: OAuthClientConfig, transport: any HTTPTransport,
                            clock: any OHClock, minimumValidity: Duration = .seconds(300),
                            onEvent: (@Sendable (TokenEvent) -> Void)? = nil) {
        self.init(store: store, client: client, transport: transport, clock: clock, minimumValidity: minimumValidity,
                  retryWaits: TokenEndpoint.refreshRetryWaits, onEvent: onEvent)
    }

    public convenience init(store: any TokenStore, client: OAuthClientConfig,
                            knownClients: @escaping @Sendable () -> [OAuthClientConfig], transport: any HTTPTransport,
                            clock: any OHClock, minimumValidity: Duration = .seconds(300),
                            onEvent: (@Sendable (TokenEvent) -> Void)? = nil) {
        self.init(store: store, client: client, transport: transport, clock: clock, minimumValidity: minimumValidity,
                  retryWaits: TokenEndpoint.refreshRetryWaits, onEvent: onEvent, knownClients: knownClients)
    }

    init(store: any TokenStore, client: OAuthClientConfig, transport: any HTTPTransport, clock: any OHClock,
         minimumValidity: Duration, retryWaits: [Duration], onEvent: (@Sendable (TokenEvent) -> Void)?,
         knownClients: (@Sendable () -> [OAuthClientConfig])? = nil) {
        self.store = store
        self.client = client
        self.transport = transport
        self.clock = clock
        self.minimumValidity = minimumValidity
        self.retryWaits = retryWaits
        self.onEvent = onEvent
        self.knownClients = knownClients
    }

    public static func accountKey(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func tokenManager(for email: String) -> TokenManager {
        let key = Self.accountKey(email)
        guard knownClients != nil else { return manager(key, client: client) }
        let minted = (try? store.load(account: key))?.clientID
        if minted == nil, let existing = managers.withLock({ $0[key]?.manager }) { return existing }
        return manager(key, client: minted.flatMap { clientWithID($0) } ?? client)
    }

    public func client(for email: String) -> OAuthClientConfig {
        guard knownClients != nil, let minted = (try? store.load(account: Self.accountKey(email)))?.clientID else {
            return client
        }
        return clientWithID(minted) ?? client
    }

    private func manager(_ key: String, client: OAuthClientConfig) -> TokenManager {
        managers.withLock { managers in
            if let existing = managers[key], existing.clientID == client.clientID { return existing.manager }
            let manager = TokenManager(account: key, store: store, client: client, transport: transport, clock: clock,
                                       minimumValidity: minimumValidity, retryWaits: retryWaits, onEvent: onEvent)
            managers[key] = Entry(manager: manager, clientID: client.clientID)
            return manager
        }
    }

    private func clientWithID(_ id: String) -> OAuthClientConfig? {
        if id == client.clientID { return client }
        return knownClients?().first { $0.clientID == id }
    }

    public func storedAccounts() throws -> [String] {
        try store.allAccounts().map(Self.accountKey).sorted()
    }

    public func grantedScopes(for email: String) throws -> [String]? {
        try store.load(account: Self.accountKey(email))?.grantedScopes
    }

    // Google's account chooser can return another account despite login_hint; that token must never replace this account's
    @discardableResult
    public func save(_ result: OAuthResult, reauthorizing expected: String? = nil) async throws -> String {
        let key = Self.accountKey(result.email)
        guard !key.isEmpty else { throw OAuthError.denied("invalid_account") }
        if let expected, Self.accountKey(expected) != key {
            Log(.oauth).error("reauthorization returned a different Google account; nothing was stored")
            throw OAuthError.denied("account_mismatch")
        }
        guard let minted = clientWithID(result.token.clientID) else { throw OAuthError.denied("client_mismatch") }
        try await manager(key, client: minted).adopt(result.token)
        return key
    }

    public func useSharedSignIn(_ email: String) async throws -> [String] {
        let key = Self.accountKey(email)
        _ = try await tokenManager(for: key).accessToken(forceRefresh: true)
        return try grantedScopes(for: key) ?? []
    }

    public func signOut(_ email: String) async throws {
        try await tokenManager(for: email).signOut()
    }

    public func authState(for email: String) async -> TokenAuthState {
        await tokenManager(for: email).authState()
    }
}
