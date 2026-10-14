import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanGmail

@Suite struct AccountCredentialsTests {
    private func registry(_ store: any TokenStore, _ transport: ScriptedTransport, _ clock: TestClock,
                          events: EventLog? = nil) -> AccountCredentials {
        AccountCredentials(store: store, client: Synthetic.client, transport: transport, clock: clock,
                           minimumValidity: .seconds(300), retryWaits: [], onEvent: events?.sink)
    }

    @Test func oneTokenManagerPerAccount() {
        let credentials = registry(InMemoryTokenStore(), ScriptedTransport(), TestClock())
        let a = credentials.tokenManager(for: "Work@Example.com")
        #expect(a === credentials.tokenManager(for: " work@example.COM "))
        #expect(a.accountEmail == "work@example.com")
        #expect(a !== credentials.tokenManager(for: "personal@example.com"))
    }

    @Test func accountsAreIndependentAndTokensNeverCross() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([
            "work@example.com": Synthetic.token(refresh: "refresh-work", expiry: clock.now.addingTimeInterval(-1)),
            "personal@example.com": Synthetic.token(refresh: "refresh-personal", expiry: nil),
        ])
        let transport = perAccountTokenEndpoint(rejected: ["refresh-work"])
        let events = EventLog()
        let credentials = registry(store, transport, clock, events: events)

        await #expect(throws: OAuthError.reauthRequired) {
            _ = try await credentials.tokenManager(for: "work@example.com").accessToken()
        }
        #expect(try await credentials.tokenManager(for: "personal@example.com").accessToken()
                == "access-for-refresh-personal")
        await #expect(throws: OAuthError.reauthRequired) {
            _ = try await credentials.tokenManager(for: "work@example.com").accessToken()
        }
        #expect(transport.requests.map { formFields($0.body)["refresh_token"] } == ["refresh-work", "refresh-personal"])
        #expect(await credentials.authState(for: "work@example.com") == .needsReauth(.invalidGrant))
        #expect(await credentials.authState(for: "personal@example.com") == .authorized)
        #expect(events.all == [.needsReauth(account: "work@example.com", reason: .invalidGrant)])
        #expect(try store.load(account: "personal@example.com")?.accessToken == "access-for-refresh-personal")
        #expect(try store.load(account: "work@example.com")?.accessToken == nil)
    }

    @Test func reauthorizationMustReturnTheSameGoogleAccount() async throws {
        let clock = TestClock()
        let original = Synthetic.token(refresh: "dead", expiry: nil)
        let store = InMemoryTokenStore(["work@example.com": original])
        let transport = perAccountTokenEndpoint(rejected: ["dead"])
        let credentials = registry(store, transport, clock)
        await #expect(throws: OAuthError.reauthRequired) {
            _ = try await credentials.tokenManager(for: "work@example.com").accessToken()
        }

        let wrong = Synthetic.result(email: "personal@example.com",
                                     token: Synthetic.token(refresh: "other", access: "a",
                                                            expiry: clock.now.addingTimeInterval(3600)))
        await #expect(throws: OAuthError.denied("account_mismatch")) {
            try await credentials.save(wrong, reauthorizing: "Work@Example.com")
        }
        #expect(try store.load(account: "work@example.com") == original)
        #expect(try store.load(account: "personal@example.com") == nil)
        #expect(await credentials.authState(for: "work@example.com") == .needsReauth(.invalidGrant))

        let right = Synthetic.result(email: "work@example.com",
                                     token: Synthetic.token(refresh: "fresh", access: "access-fresh",
                                                            expiry: clock.now.addingTimeInterval(3600),
                                                            scopes: [GmailScope.readonly]))
        #expect(try await credentials.save(right, reauthorizing: " WORK@example.com") == "work@example.com")
        #expect(try await credentials.tokenManager(for: "work@example.com").accessToken() == "access-fresh")
        #expect(try credentials.grantedScopes(for: "work@example.com") == [GmailScope.readonly])
        #expect(transport.requests.count == 1)
    }

    @Test func firstSignInIsSavedUnderTheProfileEmail() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore()
        let credentials = registry(store, ScriptedTransport(), clock)
        let key = try await credentials.save(Synthetic.result(
            email: "New@Example.com", token: Synthetic.token(refresh: "n", access: "a", expiry: clock.now)))
        #expect(key == "new@example.com")
        #expect(try credentials.storedAccounts() == ["new@example.com"])
        #expect(try credentials.grantedScopes(for: "NEW@example.com") == [GmailScope.readonly])
        #expect(try credentials.grantedScopes(for: "nobody@example.com") == nil)
    }

    @Test func signOutRemovesOnlyThatAccountAndNothingLeavesTheProcess() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([
            "work@example.com": Synthetic.token(refresh: "w", access: "aw", expiry: clock.now.addingTimeInterval(3600)),
            "personal@example.com": Synthetic.token(refresh: "p", access: "ap", expiry: clock.now.addingTimeInterval(3600)),
        ])
        let transport = ScriptedTransport()
        let credentials = registry(store, transport, clock)
        try await credentials.signOut("Work@Example.com")
        #expect(try credentials.storedAccounts() == ["personal@example.com"])
        #expect(try await credentials.tokenManager(for: "personal@example.com").accessToken() == "ap")
        await #expect(throws: OAuthError.reauthRequired) {
            _ = try await credentials.tokenManager(for: "work@example.com").accessToken()
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func factoryOverTheRegistrySharesItsTokenManagers() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([
            "work@example.com": Synthetic.token(refresh: "w", access: "aw", expiry: clock.now.addingTimeInterval(3600),
                                                scopes: [GmailScope.readonly]),
        ])
        let tokenEndpoint = ScriptedTransport()
        let credentials = registry(store, tokenEndpoint, clock)
        let api = ScriptedTransport { _ in jsonResponse(200, ["labels": []]) }
        let factory = DefaultGmailClientFactory(safeMode: .normal, accountCredentials: credentials,
                                                apiTransport: api, config: GmailClientConfig(userAgent: "t"),
                                                clock: clock)
        #expect(try factory.effectiveMode(for: "Work@Example.com") == .readOnly)
        #expect(throws: GmailError.reauthRequired) { _ = try factory.client(for: "nobody@example.com") }
        let client = try factory.client(for: "work@example.com")
        _ = try await client.listLabels()
        #expect(api.requests.first?.headers["Authorization"] == "Bearer aw")
        try await credentials.signOut("work@example.com")
        await #expect(throws: GmailError.reauthRequired) { _ = try await client.listLabels() }
        #expect(api.requests.count == 1)
        #expect(tokenEndpoint.requests.isEmpty)
    }
}
