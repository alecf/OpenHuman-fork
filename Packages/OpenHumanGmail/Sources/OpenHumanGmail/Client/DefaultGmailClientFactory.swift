import Foundation
import OpenHumanCore
import Synchronization

public final class DefaultGmailClientFactory: GmailClientFactory {
    public typealias Credentials = @Sendable (String) throws -> (tokens: any AccessTokenProvider, grantedScopes: [String])

    public let safeMode: SafeMode
    public let storeDirectory: URL?
    public let recipientGate: SendRecipientGate?
    private let apiTransport: any HTTPTransport
    private let config: GmailClientConfig
    private let clock: any OHClock
    private let metrics: @Sendable (String) -> (any GmailMetricsSink)?
    private let credentials: Credentials
    private let cache = Mutex<[String: (client: GmailClient, scopes: [String], tokens: ObjectIdentifier?)]>([:])
    // Why: kept across invalidate so a rebuilt client keeps its rights; two stores over one file would overwrite each other
    private let allowlists = Mutex<[String: WriteAllowlistStore]>([:])

    public init(safeMode: SafeMode, apiTransport: any HTTPTransport, config: GmailClientConfig, clock: any OHClock,
                storeDirectory: URL? = nil, recipientGate: SendRecipientGate? = nil,
                metrics: @escaping @Sendable (String) -> (any GmailMetricsSink)? = { _ in nil },
                credentials: @escaping Credentials) {
        self.safeMode = safeMode
        self.storeDirectory = storeDirectory
        self.recipientGate = recipientGate
        self.apiTransport = apiTransport
        self.config = config
        self.clock = clock
        self.metrics = metrics
        self.credentials = credentials
    }

    public convenience init(safeMode: SafeMode, accountCredentials: AccountCredentials,
                            apiTransport: any HTTPTransport, config: GmailClientConfig, clock: any OHClock,
                            storeDirectory: URL? = nil,
                            metrics: @escaping @Sendable (String) -> (any GmailMetricsSink)? = { _ in nil }) {
        self.init(safeMode: safeMode, apiTransport: apiTransport, config: config, clock: clock,
                  storeDirectory: storeDirectory, metrics: metrics) { email in
            guard let scopes = try accountCredentials.grantedScopes(for: email) else { throw GmailError.reauthRequired }
            return (accountCredentials.tokenManager(for: email), scopes)
        }
    }

    public convenience init(safeMode: SafeMode, tokenStore: any TokenStore, oauthClient: OAuthClientConfig,
                            apiTransport: any HTTPTransport, tokenTransport: any HTTPTransport,
                            config: GmailClientConfig, clock: any OHClock, storeDirectory: URL? = nil,
                            metrics: @escaping @Sendable (String) -> (any GmailMetricsSink)? = { _ in nil }) {
        self.init(safeMode: safeMode,
                  accountCredentials: AccountCredentials(store: tokenStore, client: oauthClient,
                                                         transport: tokenTransport, clock: clock),
                  apiTransport: apiTransport, config: config, clock: clock, storeDirectory: storeDirectory,
                  metrics: metrics)
    }

    public func client(for accountEmail: String) throws -> GmailAPI {
        try gmailClient(for: accountEmail)
    }

    public func gmailClient(for accountEmail: String) throws -> GmailClient {
        let key = accountEmail.lowercased()
        let tokens: any AccessTokenProvider, scopes: [String]
        do { (tokens, scopes) = try credentials(key) } catch {
            invalidate(accountEmail: key)
            throw error
        }
        let grant = OAuthScopes.normalized(scopes)
        let manager = (tokens as? TokenManager).map { ObjectIdentifier($0) }
        if let cached = cache.withLock({ $0[key] }), cached.scopes == grant, cached.tokens == manager { return cached.client }
        let mode = safeMode.effective(grantedScopes: scopes)
        let allowlist = mode == .writeAllowlist ? allowlist(for: key) : nil
        let transport = SafeModeTransport.wrap(apiTransport, mode: safeMode, grantedScopes: scopes, allowlist: allowlist,
                                               recipients: recipientGate)
        switch mode {
        case .normal:
            Log(.gmail).notice("gmail client in normal mode: deny-list guard (no permanent delete, settings or filters)")
        case .readOnly:
            Log(.gmail).notice("gmail client for an account in safe mode read-only: writes are refused in-process")
        case .writeAllowlist:
            Log(.gmail).notice(allowlist == nil
                ? "gmail client in safe mode write-allowlist without a usable allowlist: runs read-only"
                : "gmail client in safe mode write-allowlist: writes only to this campaign's resources (WriteGuard)")
        }
        let client = GmailClient(accountEmail: key, tokens: tokens, transport: transport, config: config, clock: clock,
                                 metrics: metrics(key))
        return cache.withLock { cache in
            if let existing = cache[key], existing.scopes == grant, existing.tokens == manager { return existing.client }
            cache[key] = (client, grant, manager)
            return client
        }
    }

    public func effectiveMode(for accountEmail: String) throws -> SafeMode {
        safeMode.effective(grantedScopes: try credentials(accountEmail.lowercased()).grantedScopes)
    }

    public func invalidate(accountEmail: String) {
        _ = cache.withLock { $0.removeValue(forKey: accountEmail.lowercased()) }
    }

    private func allowlist(for key: String) -> WriteAllowlistStore? {
        guard let storeDirectory else { return nil }
        return allowlists.withLock { open -> WriteAllowlistStore? in
            if let existing = open[key] { return existing }
            guard open.isEmpty else {
                Log(.gmail).notice("the write-allowlist campaign here belongs to another account; this one runs read-only")
                return nil
            }
            do {
                let store = try WriteAllowlistStore.open(storeDirectory: storeDirectory, accountEmail: key)
                open[key] = store
                return store
            } catch {
                Log(.gmail).error("safe-mode allowlist not usable (\(type(of: error))); the account runs read-only")
                return nil
            }
        }
    }
}
