import Foundation
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import OpenHumanSync

@MainActor
final class LiveBackend {
    struct Transports: Sendable {
        var api: any HTTPTransport
        var token: any HTTPTransport
        var unsubscribe: (any HTTPTransport)? = nil

        init(api: any HTTPTransport, token: any HTTPTransport, unsubscribe: (any HTTPTransport)? = nil) {
            self.api = api
            self.token = token
            self.unsubscribe = unsubscribe
        }
    }

    enum Start: Equatable {
        case session(AccountItem)
        case signIn(loginHint: String, notice: String?)
        case needsWriteAccess(AccountItem)
    }

    let store: MailStore
    let accounts: LiveAccountManager
    private let tokenStore: any TokenStore
    private let transports: Transports
    private let clock: any OHClock
    private let userAgent: String
    private let pollInterval: Duration?
    private let makeSystemEvents: @MainActor () -> (any StoppableSystemEvents)?
    private let calendarTokenStore: (any TokenStore)?
    private let makeReceiver: @Sendable () -> any LoopbackRedirectReceiver
    private let browser: any ExternalBrowser

    init(store: MailStore, accountDependencies: LiveAccountManager.Dependencies,
         transports: Transports, userAgent: String, pollInterval: Duration? = nil,
         makeSystemEvents: @escaping @MainActor () -> (any StoppableSystemEvents)?) {
        self.store = store
        self.tokenStore = accountDependencies.tokenStore
        self.transports = transports
        self.clock = accountDependencies.clock
        self.userAgent = userAgent
        self.pollInterval = pollInterval
        self.makeSystemEvents = makeSystemEvents
        calendarTokenStore = accountDependencies.calendarTokenStore
        makeReceiver = accountDependencies.makeReceiver
        browser = accountDependencies.browser
        accounts = LiveAccountManager(store: store, dependencies: accountDependencies)
    }

    func initialStep() -> Start {
        let known = ((try? store.accounts()) ?? []).filter { $0.status != .removing && $0.status != .disabled }
        var refusal: Start?
        for account in known {
            guard account.status == .active else {
                refusal = refusal ?? .signIn(loginHint: account.email,
                                             notice: "Google signed this account out. Sign in again.")
                continue
            }
            let token: StoredToken?
            do { token = try tokenStore.load(account: account.email) } catch {
                Log(.oauth).error("account \(account.id.rawValue): token store read failed")
                refusal = refusal ?? .signIn(loginHint: account.email, notice: Self.signInAgainNotice)
                continue
            }
            guard let token else {
                refusal = refusal ?? .signIn(loginHint: account.email, notice: Self.signInAgainNotice)
                continue
            }
            if Self.scopeRefusal(token.grantedScopes) != nil {
                refusal = refusal ?? .signIn(loginHint: account.email, notice: Self.broadAccessNotice)
                continue
            }
            if !token.grantedScopes.contains(GmailScope.modify) {
                refusal = refusal ?? .needsWriteAccess(account)
                continue
            }
            return .session(account)
        }
        return refusal ?? .signIn(loginHint: known.first?.email ?? "", notice: nil)
    }

    static let signInAgainNotice = "Mail needs you to sign in again on this Mac. Your mail here is kept."

    nonisolated static let writeAccessNotice = "To make changes, sign in again and allow Mail to change your mail."

    static let broadAccessNotice = "This account gave Mail more access than it needs. Sign in again and Mail will ask "
        + "only for what it uses."

    func makeSession(for account: AccountItem) throws -> SyncSession {
        let client = try accounts.client(for: account)
        let (tokenEvents, relay) = AsyncStream.makeStream(of: TokenEvent.self)
        let credentials = Self.credentials(tokenStore: tokenStore, accounts: accounts, client: client,
                                           transport: transports.token, clock: clock, onEvent: { relay.yield($0) })
        let gmail = GmailClientConfig(userAgent: userAgent)
        let metrics = SyncMetricsRegistry()
        let factory = DefaultGmailClientFactory(apiTransport: transports.api, config: gmail, clock: clock,
                                                metrics: { metrics.collector(for: $0) }) { email in
            try Self.credentials(email, from: credentials)
        }
        let seconds = (try? store.setting(.pollIntervalSeconds, scope: .global)) ?? 60
        let manager = accounts, wires = transports, receiver = makeReceiver, opener = browser, time = clock
        let known: @Sendable () -> [OAuthClientConfig] = { manager.knownClients() }
        var makeCalendar: LiveCalendarConnections.MakeSession?
        if let calendarTokens = calendarTokenStore {
            makeCalendar = { (email: String, owner: OAuthClientConfig) -> GoogleCalendarSession in
                GoogleCalendarSession(account: email, dependencies: GoogleCalendarSession.Dependencies(
                    tokenStore: calendarTokens, client: owner, tokenTransport: wires.token, apiTransport: wires.api,
                    makeReceiver: receiver, browser: opener, clock: time, knownClients: known,
                    pinnedScopes: { manager.calendarPinnedScopes(email: $0) },
                    recordConnect: { address, clientID, requested in
                        manager.recordCalendarConnect(email: address, clientID: clientID, requested: requested)
                    },
                    accountLabel: { manager.calendarLogLabel(email: $0) }))
            }
        }
        let calendar = makeCalendar.map { $0(account.email, client) }
        var wiring = SyncSession.Wiring(
            factory: factory, gmail: gmail, metrics: metrics, tokenStore: tokenStore, oauthClient: client, clock: clock,
            pollInterval: pollInterval ?? .seconds(max(seconds, 15)), systemEvents: makeSystemEvents(),
            tokenEvents: tokenEvents, draftsDirectory: store.location.draftsDirectory,
            unsubscribeTransport: transports.unsubscribe, accounts: accounts)
        wiring.calendar = calendar
        let connections = makeCalendar.map {
            LiveCalendarConnections(own: calendar, ownAccount: account.id, accounts: manager, make: $0)
        }
        wiring.calendarConnections = connections
        return try SyncSession(account: account, store: store, wiring: wiring, isFake: false)
    }

    nonisolated static func credentials(
        tokenStore: any TokenStore, accounts: LiveAccountManager, client: OAuthClientConfig, transport: any HTTPTransport,
        clock: any OHClock, onEvent: @escaping @Sendable (TokenEvent) -> Void
    ) -> AccountCredentials {
        AccountCredentials(store: tokenStore, client: client, knownClients: { accounts.knownClients() },
                           transport: transport, clock: clock, onEvent: onEvent)
    }

    nonisolated static func credentials(
        _ email: String, from credentials: AccountCredentials
    ) throws -> (tokens: any AccessTokenProvider, grantedScopes: [String]) {
        guard let scopes = try credentials.grantedScopes(for: email) else { throw GmailError.reauthRequired }
        if let broader = scopeRefusal(scopes) {
            Log(.oauth).error("a token carrying \(broader) is not used")
            throw GmailError.reauthRequired
        }
        return (credentials.tokenManager(for: email), scopes)
    }

    nonisolated static let acceptedMailScopes: Set<String> = [GmailScope.readonly, GmailScope.modify]

    nonisolated static func scopeRefusal(_ scopes: [String]) -> String? {
        let broader = Set(scopes).intersection(LiveAccountManager.mailWriteScopes).subtracting(acceptedMailScopes)
        return broader.isEmpty ? nil : broader.sorted().joined(separator: " ")
    }

    func account(_ id: AccountID) -> AccountItem? {
        (try? store.accounts())?.first { $0.id == id }
    }
}
