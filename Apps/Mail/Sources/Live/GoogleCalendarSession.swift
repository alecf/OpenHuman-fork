import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import Synchronization

final class GoogleCalendarSession: CalendarConnecting, Sendable {
    struct Dependencies: Sendable {
        var tokenStore: any TokenStore
        var client: OAuthClientConfig
        var tokenTransport: any HTTPTransport
        var apiTransport: any HTTPTransport
        var makeReceiver: @Sendable () -> any LoopbackRedirectReceiver
        var browser: any ExternalBrowser
        var clock: any OHClock
        var consentTimeout: Duration = .seconds(300)
        var knownClients: (@Sendable () -> [OAuthClientConfig])? = nil
        var pinnedScopes: (@Sendable (String) -> [String]?)? = nil
        var recordConnect: (@Sendable (String, String, [String]) -> Void)? = nil
        var accountLabel: (@Sendable (String) -> String)? = nil
    }

    let account: String
    let mode: SafeMode
    let provider: GoogleCalendarProvider?
    private let dependencies: Dependencies
    private let credentials: AccountCredentials
    private let runningGrant: [String]?
    private let state: Mutex<State>
    private let lateProvider = Mutex<(grant: [String], provider: GoogleCalendarProvider)?>(nil)
    private let fetches: FetchRelay

    private struct State {
        var current: CalendarConnectionState
        var watchers: [UUID: AsyncStream<CalendarConnectionState>.Continuation] = [:]
        var connecting = false
        var grant: [String]?
    }

    init(account email: String, mode: SafeMode, dependencies: Dependencies) {
        let key = AccountCredentials.accountKey(email)
        account = key
        self.mode = mode
        self.dependencies = dependencies
        let relay = TokenEventRelay()
        let fetches = FetchRelay()
        self.fetches = fetches
        let credentials: AccountCredentials
        if let known = dependencies.knownClients {
            credentials = AccountCredentials(store: dependencies.tokenStore, client: dependencies.client, knownClients: known,
                                             transport: dependencies.tokenTransport, clock: dependencies.clock,
                                             onEvent: { relay.send($0) })
        } else {
            credentials = AccountCredentials(store: dependencies.tokenStore, client: dependencies.client,
                                             transport: dependencies.tokenTransport, clock: dependencies.clock,
                                             onEvent: { relay.send($0) })
        }
        self.credentials = credentials
        var token: StoredToken?
        do { token = try dependencies.tokenStore.load(account: key) } catch {
            Log(.oauth).error("calendar token store read failed (\(String(describing: type(of: error))))")
            token = nil
        }
        var problem: String?
        if let grant = token?.grantedScopes, let pin = dependencies.pinnedScopes?(key) ?? nil,
           let beyond = CalendarScopes.beyondPinned(granted: grant, pinned: pin) {
            Log(.oauth).error("a stored calendar grant goes beyond its recorded request (\(beyond)); it is not used")
            try? dependencies.tokenStore.delete(account: key)
            token = nil
            problem = Self.broaderProblem
        }
        let stored = token?.grantedScopes
        if let stored, CalendarScopes.isUsable(stored) {
            let client = GoogleCalendarClient(calendarID: key, mode: mode, grantedScopes: stored,
                                              tokens: credentials.tokenManager(for: key),
                                              transport: dependencies.apiTransport, clock: dependencies.clock)
            provider = GoogleCalendarProvider(client: client, account: key,
                                              readOnlyReason: Self.readOnlyReason(mode: mode, grant: stored),
                                              onFetch: { fetches.send($0) })
            runningGrant = stored
        } else {
            if stored != nil { Log(.oauth).error("a stored calendar grant is not usable; it is not used") }
            provider = nil
            runningGrant = nil
        }
        let status: CalendarConnectionState.Status = problem != nil ? .needsReconnect : stored == nil ? .disconnected
            : CalendarScopes.isUsable(stored ?? []) ? .connected : .needsReconnect
        if status == .needsReconnect, problem == nil { problem = Self.unusableProblem }
        state = Mutex(State(current: CalendarConnectionState(
            status: status, account: key,
            canCreateEvents: stored.map { CalendarScopes.allowsWrites(mode: mode, granted: $0) } ?? false,
            clientShortID: token.map { OAuthClientConfig.shortID(clientID: $0.clientID) }, problem: problem,
            scopes: stored ?? []), grant: status == .connected ? stored : nil))
        relay.set { [weak self] event in self?.handle(event) }
        fetches.set { [weak self] record in self?.noteFetch(record) }
        Log(.calendar).info("\(label): calendar \(Self.statusCode(status)) at start"
            + (stored.map { " (scopes \(Self.scopeNames($0)))" } ?? ""))
    }

    private var label: String { dependencies.accountLabel?(account) ?? "a calendar" }

    static func statusCode(_ status: CalendarConnectionState.Status) -> String {
        switch status {
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .needsReconnect: "needsReconnect"
        }
    }

    static func scopeNames(_ scopes: [String]) -> String {
        scopes.map(CalendarConnectionState.scopeName).sorted().joined(separator: " ")
    }

    static func describe(_ record: CalendarFetchRecord) -> String {
        let hours = Int((record.to.timeIntervalSince(record.from) / 3_600).rounded())
        return "\(record.kind.rawValue) \(record.from.formatted(.iso8601)) +\(hours)h"
    }

    static func fetchLine(_ label: String, _ record: CalendarFetchRecord) -> String {
        let ms = Int((record.duration / .milliseconds(1)).rounded())
        if let failure = record.failure { return "\(label): \(describe(record)) failed (\(failure)) after \(ms) ms" }
        return "\(label): \(describe(record)): \(record.count ?? 0) in \(ms) ms"
    }

    static func connectLine(_ label: String, scopes: [String]) -> String {
        "\(label): calendar connected (scopes \(scopeNames(scopes))); used now, no relaunch"
    }

    private func noteFetch(_ record: CalendarFetchRecord) {
        if record.failure != nil {
            Log(.calendar).error(Self.fetchLine(label, record))
        } else {
            Log(.calendar).info(Self.fetchLine(label, record))
        }
        let now = dependencies.clock.now
        let (current, watchers) = state.withLock { s -> (CalendarConnectionState, [AsyncStream<CalendarConnectionState>.Continuation]) in
            s.current.lastFetch = now
            s.current.lastFetchError = record.failure
            if record.failure == nil { s.current.lastRefreshed = now }
            return (s.current, Array(s.watchers.values))
        }
        for watcher in watchers { watcher.yield(current) }
    }

    static let broaderProblem = "Google gave Mail more calendar access than it asked for, so Mail stopped using it. "
        + "Reconnect to give exactly what Mail asks for."
    static let unusableProblem = "The calendar access stored on this Mac isn't one Mail can use. Reconnect."
    static let revokedProblem = "Google no longer accepts Mail's calendar access (it was removed or expired). Reconnect."
    static let clientGoneProblem = "The Google client this calendar connected with isn't on this Mac any more. Import its "
        + "file again, or reconnect with another client."
    static let goneProblem = "Mail's calendar access is no longer on this Mac. Reconnect."

    static func problem(_ reason: ReauthReason) -> String {
        switch reason {
        case .invalidGrant: revokedProblem
        case .broaderGrant: broaderProblem
        case .clientMismatch: clientGoneProblem
        case .noToken, .signedOut: goneProblem
        case .needsSignInHere: unusableProblem
        }
    }

    func resume() async {
        guard provider != nil else { return }
        do {
            _ = try await credentials.tokenManager(for: account).accessToken(forceRefresh: false)
            Log(.calendar).info("\(label): calendar access refreshed at launch")
            noteRead()
        } catch {
            Log(.oauth).notice("calendar resume did not refresh (\(String(describing: type(of: error))))")
            Log(.calendar).notice("\(label): calendar refresh at launch failed (\(String(describing: type(of: error))))")
        }
    }

    var currentProvider: GoogleCalendarProvider? {
        let (status, known) = state.withLock { ($0.current.status, $0.grant) }
        guard status == .connected, let grant = known, CalendarScopes.isUsable(grant) else { return nil }
        if let provider, let runningGrant, Set(runningGrant) == Set(grant) { return provider }
        return lateProvider.withLock { late -> GoogleCalendarProvider in
            if let late, Set(late.grant) == Set(grant) { return late.provider }
            let client = GoogleCalendarClient(calendarID: account, mode: mode, grantedScopes: grant,
                                              tokens: credentials.tokenManager(for: account),
                                              transport: dependencies.apiTransport, clock: dependencies.clock)
            let fetches = self.fetches
            let made = GoogleCalendarProvider(client: client, account: account,
                                              readOnlyReason: Self.readOnlyReason(mode: mode, grant: grant),
                                              onFetch: { fetches.send($0) })
            late = (grant, made)
            return made
        }
    }

    private func noteRead() {
        let now = dependencies.clock.now
        let (current, watchers) = state.withLock { s -> (CalendarConnectionState, [AsyncStream<CalendarConnectionState>.Continuation]) in
            s.current.lastRefreshed = now
            return (s.current, Array(s.watchers.values))
        }
        for watcher in watchers { watcher.yield(current) }
    }

    static func readOnlyReason(mode: SafeMode, grant: [String]) -> String? {
        if CalendarScopes.allowsWrites(mode: mode, granted: grant) { return nil }
        if mode == .readOnly { return "Read-only safe mode: Mail never creates calendar events." }
        return "Connected read-only. To create events, turn Connect Google Calendar off and on again (Settings › Calendar)."
    }

    func connectionStates() -> AsyncStream<CalendarConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CalendarConnectionState>.makeStream()
        let current = state.withLock { s -> CalendarConnectionState in
            s.watchers[id] = continuation
            return s.current
        }
        continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.watchers.removeValue(forKey: id) } }
        continuation.yield(current)
        return stream
    }

    func connect() async throws {
        let started = state.withLock { s -> Bool in
            guard !s.connecting else { return false }
            s.connecting = true
            return true
        }
        guard started else { throw CalendarError.refused("Mail is already waiting for Google in your browser.") }
        defer { state.withLock { $0.connecting = false } }
        let consent = CalendarConsent(client: dependencies.client, mode: mode, transport: dependencies.tokenTransport,
                                      receiver: dependencies.makeReceiver(), browser: dependencies.browser,
                                      clock: dependencies.clock)
        let token: StoredToken
        do {
            token = try await consent.authorize(account: account, timeout: dependencies.consentTimeout)
        } catch {
            throw Self.connectError(error)
        }
        do {
            try await adopt(token)
        } catch {
            Log(.oauth).error("calendar token could not be stored (\(String(describing: type(of: error))))")
            throw CalendarError.failed("Google said yes, but Mail couldn't save the calendar access. Try again.")
        }
        dependencies.recordConnect?(account, token.clientID, consent.scopes)
        Log(.oauth).notice("calendar connected (\(token.grantedScopes.count) scopes)")
        Log(.calendar).notice(Self.connectLine(label, scopes: token.grantedScopes))
        publish(status: .connected, grant: token.grantedScopes, clientID: token.clientID)
    }

    func disconnect() async throws {
        do {
            try await credentials.signOut(account)
        } catch {
            Log(.oauth).error("calendar token could not be deleted (\(String(describing: type(of: error))))")
            throw CalendarError.failed("Mail couldn't remove its calendar access from this Mac. Try again.")
        }
        Log(.oauth).notice("calendar disconnected locally; nothing was revoked at Google")
        Log(.calendar).notice("\(label): calendar disconnected on this Mac; nothing was revoked at Google")
        publish(status: .disconnected, grant: nil)
    }

    func forget() async {
        try? await credentials.signOut(account)
        publish(status: .disconnected, grant: nil)
    }

    func reloadStoredGrant() {
        let token: StoredToken?
        do { token = try dependencies.tokenStore.load(account: account) } catch {
            Log(.oauth).error("calendar token store read failed (\(String(describing: type(of: error))))")
            return
        }
        guard let token else { return publish(status: .disconnected, grant: nil) }
        let usable = CalendarScopes.isUsable(token.grantedScopes)
        publish(status: usable ? .connected : .needsReconnect, grant: token.grantedScopes, clientID: token.clientID,
                problem: usable ? nil : Self.unusableProblem)
    }

    private func adopt(_ token: StoredToken) async throws {
        guard dependencies.knownClients != nil else { return try await credentials.tokenManager(for: account).adopt(token) }
        let minting = AccountCredentials(store: dependencies.tokenStore, client: dependencies.client,
                                         transport: dependencies.tokenTransport, clock: dependencies.clock)
        try await minting.tokenManager(for: account).adopt(token)
    }

    private func handle(_ event: TokenEvent) {
        switch event {
        case .needsReauth(_, let reason) where reason != .signedOut:
            Log(.oauth).notice("calendar needs to be connected again (\(reason.rawValue))")
            Log(.calendar).notice("\(label): calendar needs connecting again (\(reason.rawValue))")
            publish(status: .needsReconnect, grant: nil, problem: Self.problem(reason))
        case .scopesChanged(_, let scopes):
            let usable = CalendarScopes.isUsable(scopes)
            publish(status: usable ? .connected : .needsReconnect, grant: scopes,
                    problem: usable ? nil : Self.unusableProblem)
        default:
            break
        }
    }

    private func publish(status: CalendarConnectionState.Status, grant: [String]?, clientID: String? = nil,
                         problem: String? = nil) {
        let (current, watchers) = state.withLock { s -> (CalendarConnectionState, [AsyncStream<CalendarConnectionState>.Continuation]) in
            s.current.status = status
            s.current.problem = problem
            if let clientID { s.current.clientShortID = OAuthClientConfig.shortID(clientID: clientID) }
            if status == .disconnected { s.current.clientShortID = nil }
            s.current.canCreateEvents = grant.map { CalendarScopes.allowsWrites(mode: mode, granted: $0) } ?? false
            s.current.scopes = grant ?? []
            s.grant = status == .connected ? grant : nil
            s.current.needsRestart = false
            return (s.current, Array(s.watchers.values))
        }
        for watcher in watchers { watcher.yield(current) }
    }

    static func connectError(_ error: Error) -> CalendarError {
        switch error {
        case OAuthError.cancelled, OAuthError.denied("access_denied"), is CancellationError:
            return .refused("Connecting was cancelled. Nothing was stored.")
        case OAuthError.timedOut:
            return .failed("Google didn't answer in time. Try again.")
        case OAuthError.insufficientScopes:
            return .refused("Google didn't grant calendar access (a box was left unticked). Nothing was stored.")
        case OAuthError.denied("calendar grant refused"):
            return .refused("Google granted more than Mail asks for, so Mail refused it. Nothing was stored.")
        case OAuthError.tokenEndpoint(let status, let code, _):
            return .failed("Google refused (HTTP \(status)\(code.map { ", \($0)" } ?? "")). Nothing was stored.")
        case is TransportError:
            return .failed("Couldn't reach Google. Check the connection and try again.")
        default:
            return .failed("Connecting didn't work. Nothing was stored. Try again.")
        }
    }
}

private final class FetchRelay: Sendable {
    private let target = Mutex<(@Sendable (CalendarFetchRecord) -> Void)?>(nil)

    func set(_ handler: @escaping @Sendable (CalendarFetchRecord) -> Void) {
        target.withLock { $0 = handler }
    }

    func send(_ record: CalendarFetchRecord) {
        target.withLock { $0 }?(record)
    }
}

private final class TokenEventRelay: Sendable {
    private let target = Mutex<(@Sendable (TokenEvent) -> Void)?>(nil)

    func set(_ handler: @escaping @Sendable (TokenEvent) -> Void) {
        target.withLock { $0 = handler }
    }

    func send(_ event: TokenEvent) {
        target.withLock { $0 }?(event)
    }
}
