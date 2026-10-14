import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct EngineAccountsTests {
    private struct Rig {
        let clock = TestClock(now: currentMinute())
        let gmail: FakeGmail
        let tokens = InMemoryTokenStore()
        let store: MailStore
        let factory: DefaultGmailClientFactory
        let google: FakeGoogleSignIn

        init(safeMode: SafeMode = .normal, scope: String = GmailScope.modify, signInEmail: String? = nil) async throws {
            gmail = FakeGmail(accountEmail: "me@example.com", clock: clock, startDate: clock.now.addingTimeInterval(-86_400))
            await gmail.seedInbox(count: 3)
            store = try MailStore.openInMemoryForTesting()
            google = FakeGoogleSignIn(gmail: gmail, clock: clock, email: signInEmail, scope: scope)
            factory = DefaultGmailClientFactory(safeMode: safeMode, tokenStore: tokens, oauthClient: FakeGoogleSignIn.client,
                                                apiTransport: FakeGmailTransport(gmail), tokenTransport: google.transport,
                                                config: engineGmailConfig, clock: clock)
        }

        func engine(_ safeMode: SafeMode = .normal) -> MailEngine {
            MailEngine(store: store, gmailFactory: factory, tokenStore: tokens, oauthClient: FakeGoogleSignIn.client,
                       configuration: EngineConfiguration(role: .app, appVersion: "0.0.0-test", gmail: engineGmailConfig,
                                                          clock: clock, safeMode: safeMode),
                       systemEvents: nil)
        }
    }

    @Test func anAccountWithoutATokenWaitsForReauthorizationThenSyncs() async throws {
        let rig = try await Rig()
        let account = try rig.store.addAccount(email: "me@example.com", displayName: nil, scopes: [GmailScope.modify])
        let engine = rig.engine()
        await engine.start()
        #expect(await engine.runtime(for: account) == nil)
        #expect(try rig.store.accounts().first?.status == .needsReauth)
        #expect(engine.connectivity.current[account] == .needsReauth)

        try await engine.reauthorize(account, using: rig.google.flow(.normal))
        #expect(try rig.tokens.load(account: "me@example.com") != nil)
        #expect(try rig.store.accounts().first?.status == .active)
        try await eventually("synced after reauthorization") {
            try rig.store.threadPage(view: .system(account, .inbox), after: nil, limit: 10).items.count == 3
        }
        await engine.stop()
    }

    @Test func aReauthorizationThatReturnsAnotherAccountStoresNothing() async throws {
        let rig = try await Rig(signInEmail: "someone.else@example.com")
        let account = try rig.store.addAccount(email: "me@example.com", displayName: nil, scopes: [GmailScope.modify])
        let engine = rig.engine()
        await #expect(throws: OAuthError.denied("account_mismatch")) {
            try await engine.reauthorize(account, using: rig.google.flow(.normal))
        }
        #expect(try rig.tokens.allAccounts().isEmpty)
    }

    @Test func signInRequestsExactlyTheSafeModesScope() async throws {
        let rig = try await Rig(safeMode: .readOnly, scope: GmailScope.readonly)
        let engine = rig.engine(.readOnly)
        await engine.start()
        await #expect(throws: EngineError.blockedBySafeMode("sign-in must request exactly the read-only scope")) {
            try await engine.addAccount(using: rig.google.flow(.normal), loginHint: nil)
        }
        #expect(rig.google.transport.requests.isEmpty)
        let account = try await engine.addAccount(using: rig.google.flow(.readOnly), loginHint: nil)
        #expect(account.grantedScopes == [GmailScope.readonly])
        try await eventually("synced read-only") { await engine.runtime(for: account.id) != nil }
        #expect(await engine.drainer(for: account.id) == nil)
        await engine.stop()
    }

    @Test func removalSignsOutLocallyAndRemovesTheData() async throws {
        let rig = try await Rig()
        let engine = rig.engine()
        await engine.start()
        let account = try await engine.addAccount(using: rig.google.flow(.normal), loginHint: "me@example.com")
        try await eventually("synced") {
            try rig.store.threadPage(view: .system(account.id, .inbox), after: nil, limit: 10).items.count == 3
        }
        try await engine.removeAccount(account.id)
        #expect(try rig.tokens.load(account: "me@example.com") == nil)
        #expect(try rig.store.accounts().isEmpty)
        #expect(try rig.store.lease(account: account.id) == nil)
        #expect(await engine.runtime(for: account.id) == nil)
        #expect(rig.google.transport.requests.allSatisfy { !$0.url.absoluteString.contains("revoke") })
        await engine.stop()
    }
}
