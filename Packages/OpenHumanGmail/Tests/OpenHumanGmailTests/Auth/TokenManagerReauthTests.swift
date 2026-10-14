import Foundation
import OpenHumanCore
import Synchronization
import Testing
@testable import OpenHumanGmail

@Suite struct TokenManagerReauthTests {
    private let email = "someone@example.com"

    private func manager(_ store: any TokenStore, _ transport: ScriptedTransport, _ clock: TestClock,
                         events: EventLog? = nil) -> TokenManager {
        TokenManager(account: email, store: store, client: Synthetic.client, transport: transport, clock: clock,
                     minimumValidity: .seconds(300), retryWaits: [], onEvent: events?.sink)
    }

    @Test func invalidGrantIsStickyUntilADifferentCredentialIsStored() async throws {
        let clock = TestClock()
        let old = Synthetic.token(refresh: "refresh-old", expiry: clock.now.addingTimeInterval(-1))
        let store = InMemoryTokenStore([email: old])
        let transport = perAccountTokenEndpoint(rejected: ["refresh-old"])
        let events = EventLog()
        let tokens = manager(store, transport, clock, events: events)

        #expect(await tokens.authState() == .unknown)
        await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken() }
        #expect(await tokens.authState() == .needsReauth(.invalidGrant))
        #expect(transport.requests.count == 1)

        for force in [false, true, false] {
            await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken(forceRefresh: force) }
        }
        try store.save(old, account: email)
        await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken() }
        #expect(transport.requests.count == 1)
        #expect(events.all == [.needsReauth(account: email, reason: .invalidGrant)])

        try store.save(Synthetic.token(refresh: "refresh-new", expiry: clock.now.addingTimeInterval(-1)), account: email)
        #expect(try await tokens.accessToken() == "access-for-refresh-new")
        #expect(await tokens.authState() == .authorized)
        #expect(transport.requests.count == 2)
        #expect(formFields(transport.requests[1].body)["refresh_token"] == "refresh-new")
    }

    @Test func noTokenNeedsReauthWithoutAnyRequestAndRecoversOnSignIn() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore()
        let transport = perAccountTokenEndpoint(rejected: [])
        let tokens = manager(store, transport, clock)
        await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken() }
        #expect(await tokens.authState() == .needsReauth(.noToken))
        try store.save(Synthetic.token(refresh: "r1", access: "access-1", expiry: clock.now.addingTimeInterval(3600)),
                       account: email)
        #expect(try await tokens.accessToken() == "access-1")
        #expect(transport.requests.isEmpty)
        #expect(await tokens.authState() == .authorized)
    }

    @Test func aTokenOfAnotherClientIsNeverSentToGoogleAndStaysRefused() async throws {
        let clock = TestClock()
        let foreign = Synthetic.token(refresh: "foreign", expiry: nil, clientID: "another-client.apps.example")
        let store = InMemoryTokenStore([email: foreign])
        let transport = perAccountTokenEndpoint(rejected: [])
        let tokens = manager(store, transport, clock)
        await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken() }
        #expect(await tokens.authState() == .needsReauth(.clientMismatch))
        try store.save(Synthetic.token(refresh: "foreign-2", expiry: nil, clientID: "another-client.apps.example"),
                       account: email)
        await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken() }
        #expect(transport.requests.isEmpty)
        try await tokens.adopt(Synthetic.token(refresh: "ours", access: "access-ours",
                                               expiry: clock.now.addingTimeInterval(3600)))
        #expect(try await tokens.accessToken() == "access-ours")
        #expect(transport.requests.isEmpty)
    }

    @Test func adoptReplacesTheCredentialAndRefusesAnotherClientsToken() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(refresh: "dead", expiry: nil)])
        let transport = perAccountTokenEndpoint(rejected: ["dead"])
        let events = EventLog()
        let tokens = manager(store, transport, clock, events: events)
        await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken() }

        let wrongClient = Synthetic.token(refresh: "x", access: "a", expiry: clock.now.addingTimeInterval(3600),
                                          clientID: "another-client.apps.example")
        await #expect(throws: OAuthError.denied("client_mismatch")) { try await tokens.adopt(wrongClient) }
        #expect(try store.load(account: email)?.refreshToken == "dead")

        let fresh = Synthetic.token(refresh: "fresh", access: "access-fresh", expiry: clock.now.addingTimeInterval(3600),
                                    scopes: [GmailScope.readonly])
        try await tokens.adopt(fresh)
        #expect(try store.load(account: email) == fresh)
        #expect(await tokens.authState() == .authorized)
        #expect(try await tokens.accessToken() == "access-fresh")
        #expect(transport.requests.count == 1)
        #expect(events.all == [.needsReauth(account: email, reason: .invalidGrant),
                               .authorized(account: email, scopes: [GmailScope.readonly])])
    }

    @Test func signOutDeletesOnlyThisAccountsItemAndNeverContactsGoogle() async throws {
        let clock = TestClock()
        let other = "other@example.com"
        let store = InMemoryTokenStore([
            email: Synthetic.token(refresh: "mine", access: "access-mine", expiry: clock.now.addingTimeInterval(3600)),
            other: Synthetic.token(refresh: "theirs", expiry: nil),
        ])
        let transport = perAccountTokenEndpoint(rejected: [])
        let events = EventLog()
        let tokens = manager(store, transport, clock, events: events)
        #expect(try await tokens.accessToken() == "access-mine")

        try await tokens.signOut()
        #expect(try store.load(account: email) == nil)
        #expect(try store.load(account: other)?.refreshToken == "theirs")
        #expect(await tokens.authState() == .needsReauth(.signedOut))
        await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken() }
        await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken(forceRefresh: true) }
        #expect(transport.requests.isEmpty)
        #expect(events.all == [.signedOut(account: email)])
    }

    @Test func aFailedDeleteStillLeavesTheAccountSignedOut() async throws {
        struct DeleteFails: TokenStore {
            let inner: InMemoryTokenStore
            func load(account email: String) throws -> StoredToken? { try inner.load(account: email) }
            func save(_ token: StoredToken, account email: String) throws { try inner.save(token, account: email) }
            func delete(account email: String) throws { throw TokenStoreError.keychain(-25308) }
            func allAccounts() throws -> [String] { try inner.allAccounts() }
        }
        let clock = TestClock()
        let inner = InMemoryTokenStore([email: Synthetic.token(refresh: "kept", access: "a",
                                                               expiry: clock.now.addingTimeInterval(3600))])
        let transport = perAccountTokenEndpoint(rejected: [])
        let tokens = manager(DeleteFails(inner: inner), transport, clock)
        await #expect(throws: TokenStoreError.keychain(-25308)) { try await tokens.signOut() }
        await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken() }
        #expect(transport.requests.isEmpty)
    }

    @Test func signOutDuringARefreshOnTheWireDoesNotResurrectTheToken() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(refresh: "r", expiry: clock.now.addingTimeInterval(-1))])
        let gate = Gate()
        let transport = ScriptedTransport { _ in
            await gate.wait()
            return jsonResponse(200, ["access_token": "late-access", "expires_in": 3600, "scope": GmailScope.readonly])
        }
        let tokens = manager(store, transport, clock)
        let caller = Task { try await tokens.accessToken() }
        #expect(await eventually { transport.requests.count == 1 })
        try await tokens.signOut()
        gate.open()
        await #expect(throws: OAuthError.reauthRequired) { _ = try await caller.value }
        #expect(try store.load(account: email) == nil)
        #expect(await tokens.authState() == .needsReauth(.signedOut))
    }

    @Test func aSignInDuringARefreshOnTheWireWins() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(refresh: "r", expiry: clock.now.addingTimeInterval(-1))])
        let gate = Gate()
        let transport = ScriptedTransport { _ in
            await gate.wait()
            return jsonResponse(200, ["access_token": "stale-access", "expires_in": 3600])
        }
        let tokens = manager(store, transport, clock)
        let caller = Task { try await tokens.accessToken() }
        #expect(await eventually { transport.requests.count == 1 })
        let adopted = Synthetic.token(refresh: "new", access: "adopted-access", expiry: clock.now.addingTimeInterval(3600))
        try await tokens.adopt(adopted)
        gate.open()
        #expect(try await caller.value == "adopted-access")
        #expect(try store.load(account: email) == adopted)
    }

    @Test func refreshKeepsTheGrantedScopesCurrent() async throws {
        let clock = TestClock()
        let both = [GmailScope.modify, GmailScope.readonly]
        let store = InMemoryTokenStore([email: Synthetic.token(refresh: "r", expiry: nil, scopes: both)])
        let scope = Mutex<String?>("\(GmailScope.readonly) \(GmailScope.modify)")
        let transport = ScriptedTransport { _ in
            var body: [String: Any] = ["access_token": "a", "expires_in": 60]
            if let value = scope.withLock({ $0 }) { body["scope"] = value }
            return jsonResponse(200, body)
        }
        let events = EventLog()
        let tokens = manager(store, transport, clock, events: events)

        _ = try await tokens.accessToken()
        #expect(events.all.isEmpty)
        scope.withLock { $0 = nil }
        _ = try await tokens.accessToken()
        #expect(try await tokens.grantedScopes() == both)
        scope.withLock { $0 = "\(GmailScope.modify) \(GmailScope.readonly) \(GmailScope.modify)" }
        _ = try await tokens.accessToken()
        #expect(events.all.isEmpty)
        scope.withLock { $0 = GmailScope.readonly }
        _ = try await tokens.accessToken()
        #expect(try await tokens.grantedScopes() == [GmailScope.readonly])
        #expect(try store.load(account: email)?.grantedScopes == [GmailScope.readonly])
        scope.withLock { $0 = "\(GmailScope.readonly) openid" }
        _ = try await tokens.accessToken()
        let withIdentity = [GmailScope.readonly, "openid"]
        #expect(try await tokens.grantedScopes() == withIdentity)
        #expect(events.all == [.scopesChanged(account: email, scopes: [GmailScope.readonly]),
                               .scopesChanged(account: email, scopes: withIdentity)])
        #expect(await tokens.authState() == .authorized)
        #expect(transport.requests.count == 5)
    }

    @Test func aRefreshGrantingMoreThanTheStoredGrantIsNeverUsed() async throws {
        let cases: [(stored: [String], refreshed: String)] = [
            ([GmailScope.readonly], "\(GmailScope.readonly) \(GmailScope.modify)"),
            ([GmailScope.readonly], GmailScope.modify),
            ([GmailScope.modify], "\(GmailScope.modify) https://mail.google.com/"),
            ([GmailScope.modify, GmailScope.readonly], "https://mail.google.com/"),
            ([GmailScope.readonly], "\(GmailScope.readonly) https://www.googleapis.com/auth/gmail.send"),
            ([GmailScope.modify], "\(GmailScope.modify) https://www.googleapis.com/auth/gmail.settings.basic"),
            ([GmailScope.modify], "\(GmailScope.modify) https://www.googleapis.com/auth/drive.readonly"),
        ]
        for (stored, refreshed) in cases {
            let clock = TestClock()
            let store = InMemoryTokenStore([email: Synthetic.token(refresh: "r", expiry: nil, scopes: stored)])
            let transport = ScriptedTransport { _ in
                jsonResponse(200, ["access_token": "broader-access", "expires_in": 3600, "scope": refreshed,
                                   "refresh_token": "rotated"])
            }
            let events = EventLog()
            let tokens = manager(store, transport, clock, events: events)
            await #expect(throws: OAuthError.reauthRequired, "\(refreshed)") { _ = try await tokens.accessToken() }
            #expect(await tokens.authState() == .needsReauth(.broaderGrant), "\(refreshed)")
            #expect(events.all == [.needsReauth(account: email, reason: .broaderGrant)], "\(refreshed)")
            #expect(try store.load(account: email) == nil, "\(refreshed): the app's own token item is deleted")
            await #expect(throws: OAuthError.reauthRequired) { _ = try await tokens.accessToken(forceRefresh: true) }
            #expect(transport.requests.count == 1, "\(refreshed)")
            try await tokens.adopt(Synthetic.token(refresh: "new", access: "signed-in", expiry: clock.now.addingTimeInterval(3600),
                                                   scopes: stored))
            #expect(try await tokens.accessToken() == "signed-in")
        }
        let clock = TestClock()
        let store = InMemoryTokenStore([email: Synthetic.token(refresh: "r", expiry: nil, scopes: [GmailScope.modify])])
        let transport = ScriptedTransport { _ in
            jsonResponse(200, ["access_token": "a", "expires_in": 3600,
                               "scope": "\(GmailScope.modify) \(GmailScope.readonly)"])
        }
        #expect(try await manager(store, transport, clock).accessToken() == "a")
    }

    @Test func accountKeysAreTrimmedAndLowercased() {
        let tokens = TokenManager(account: "  Someone@Example.COM\n", store: InMemoryTokenStore(),
                                  client: Synthetic.client, transport: ScriptedTransport(), clock: TestClock())
        #expect(tokens.accountEmail == "someone@example.com")
    }
}
