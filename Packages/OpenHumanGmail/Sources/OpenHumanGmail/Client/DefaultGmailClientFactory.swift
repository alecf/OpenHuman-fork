import Foundation
import OpenHumanCore
import Synchronization

public final class DefaultGmailClientFactory: GmailClientFactory {
    public typealias Credentials = @Sendable (String) throws -> (tokens: any AccessTokenProvider, grantedScopes: [String])

    public let recipientGate: SendRecipientGate?
    private let apiTransport: DenyListTransport
    private let config: GmailClientConfig
    private let clock: any OHClock
    private let metrics: @Sendable (String) -> (any GmailMetricsSink)?
    private let credentials: Credentials
    private let cache = Mutex<[String: (client: GmailClient, scopes: [String], tokens: ObjectIdentifier?)]>([:])

    public init(apiTransport: any HTTPTransport, config: GmailClientConfig, clock: any OHClock,
                recipientGate: SendRecipientGate? = nil,
                metrics: @escaping @Sendable (String) -> (any GmailMetricsSink)? = { _ in nil },
                credentials: @escaping Credentials) {
        self.recipientGate = recipientGate
        self.apiTransport = DefaultGmailClientFactory.guarded(apiTransport, recipients: recipientGate)
        self.config = config
        self.clock = clock
        self.metrics = metrics
        self.credentials = credentials
    }

    public convenience init(accountCredentials: AccountCredentials,
                            apiTransport: any HTTPTransport, config: GmailClientConfig, clock: any OHClock,
                            metrics: @escaping @Sendable (String) -> (any GmailMetricsSink)? = { _ in nil }) {
        self.init(apiTransport: apiTransport, config: config, clock: clock, metrics: metrics) { email in
            guard let scopes = try accountCredentials.grantedScopes(for: email) else { throw GmailError.reauthRequired }
            return (accountCredentials.tokenManager(for: email), scopes)
        }
    }

    public convenience init(tokenStore: any TokenStore, oauthClient: OAuthClientConfig,
                            apiTransport: any HTTPTransport, tokenTransport: any HTTPTransport,
                            config: GmailClientConfig, clock: any OHClock,
                            metrics: @escaping @Sendable (String) -> (any GmailMetricsSink)? = { _ in nil }) {
        self.init(accountCredentials: AccountCredentials(store: tokenStore, client: oauthClient,
                                                         transport: tokenTransport, clock: clock),
                  apiTransport: apiTransport, config: config, clock: clock, metrics: metrics)
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
        guard scopes.contains(GmailScope.modify) else {
            invalidate(accountEmail: key)
            Log(.gmail).notice("gmail client refused: the grant lacks gmail.modify, so the account must sign in again")
            throw GmailError.reauthRequired
        }
        let grant = OAuthScopes.normalized(scopes)
        let manager = (tokens as? TokenManager).map { ObjectIdentifier($0) }
        if let cached = cache.withLock({ $0[key] }), cached.scopes == grant, cached.tokens == manager { return cached.client }
        Log(.gmail).notice("gmail client behind the deny list (no permanent delete, settings or filters)")
        let client = GmailClient(accountEmail: key, tokens: tokens, transport: apiTransport, config: config, clock: clock,
                                 metrics: metrics(key))
        return cache.withLock { cache in
            if let existing = cache[key], existing.scopes == grant, existing.tokens == manager { return existing.client }
            cache[key] = (client, grant, manager)
            return client
        }
    }

    public func invalidate(accountEmail: String) {
        _ = cache.withLock { $0.removeValue(forKey: accountEmail.lowercased()) }
    }

    static func guarded(_ transport: any HTTPTransport, recipients: SendRecipientGate?) -> DenyListTransport {
        if let guarded = transport as? DenyListTransport, guarded.recipients === recipients { return guarded }
        return DenyListTransport(wrapping: transport, recipients: recipients)
    }
}
