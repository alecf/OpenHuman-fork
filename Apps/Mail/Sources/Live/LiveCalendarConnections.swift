import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import Synchronization

final class LiveCalendarConnections: CalendarConnectionsProviding, Sendable {
    typealias MakeSession = @Sendable (_ email: String, _ client: OAuthClientConfig) -> GoogleCalendarSession

    private let own: GoogleCalendarSession?
    private let ownAccount: AccountID
    private let accounts: LiveAccountManager
    private let make: MakeSession
    private let cache = Mutex<[AccountID: LiveInboxCalendar]>([:])

    init(own: GoogleCalendarSession?, ownAccount: AccountID, accounts: LiveAccountManager, make: @escaping MakeSession) {
        self.own = own
        self.ownAccount = ownAccount
        self.accounts = accounts
        self.make = make
    }

    func calendarConnection(for account: Account) -> (any CalendarConnecting)? {
        inbox(account.id, email: account.email)
    }

    func calendarProvider(for account: Account) -> (any CalendarProviding)? {
        inbox(account.id, email: account.email)?.primary.currentProvider
    }

    var routesByAccount: Bool { true }

    func windowCalendarProvider() -> (any CalendarProviding)? {
        if let own = own?.currentProvider { return own }
        for (id, email) in accounts.signedInAccounts() where id != ownAccount {
            if let found = inbox(id, email: email)?.primary.currentProvider { return found }
        }
        return nil
    }

    func resume(_ accounts: [(id: AccountID, email: String)]) async {
        for (id, email) in accounts {
            await inbox(id, email: email)?.primary.resume()
        }
    }

    private func inbox(_ id: AccountID, email: String) -> LiveInboxCalendar? {
        if let cached = cache.withLock({ $0[id] }) { return cached }
        guard let client = accounts.ownClient(email: email, account: id) ?? (try? accounts.loadClient())
        else { return nil }
        let primary = id == ownAccount ? (own ?? make(email, client)) : make(email, client)
        let accounts = self.accounts
        let make = self.make
        let made = LiveInboxCalendar(primary: primary, ownClientKey: client.registryKey, alternate: { key in
            accounts.knownClients().first { $0.registryKey == key }.map { make(email, $0) }
        }, recordedClientKey: { accounts.calendarClientKey(email: email) })
        return cache.withLock { cache in
            if let raced = cache[id] { return raced }
            cache[id] = made
            return made
        }
    }

    func forget(_ account: AccountID) async {
        guard let gone = cache.withLock({ $0.removeValue(forKey: account) }) else { return }
        if account != ownAccount { await gone.primary.forget() }
    }
}

final class LiveInboxCalendar: CalendarConnecting, Sendable {
    let primary: GoogleCalendarSession
    private let ownClientKey: String
    private let alternate: @Sendable (String) -> GoogleCalendarSession?
    private let recordedClientKey: @Sendable () -> String?

    init(primary: GoogleCalendarSession, ownClientKey: String,
         alternate: @escaping @Sendable (String) -> GoogleCalendarSession?,
         recordedClientKey: @escaping @Sendable () -> String? = { nil }) {
        self.primary = primary
        self.ownClientKey = ownClientKey
        self.alternate = alternate
        self.recordedClientKey = recordedClientKey
    }

    func connectionStates() -> AsyncStream<CalendarConnectionState> { primary.connectionStates() }

    func connect() async throws { try await primary.connect() }

    func connect(client: OAuthClientSummary.ID?) async throws {
        if client == nil, let recorded = recordedClientKey(), recorded != ownClientKey, let other = alternate(recorded) {
            try await other.connect()
            primary.reloadStoredGrant()
            return
        }
        guard let client, client != ownClientKey else { return try await primary.connect() }
        guard let other = alternate(client) else {
            throw CalendarError.refused("That Google client is no longer on this Mac. Import its file again in "
                + "Settings › Accounts. Nothing was stored.")
        }
        try await other.connect()
        primary.reloadStoredGrant()
    }

    func disconnect() async throws { try await primary.disconnect() }
}
