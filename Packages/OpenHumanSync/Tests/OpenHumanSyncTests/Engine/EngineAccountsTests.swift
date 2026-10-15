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

        init(scope: String = GmailScope.modify, signInEmail: String? = nil) async throws {
            gmail = FakeGmail(accountEmail: "me@example.com", clock: clock, startDate: clock.now.addingTimeInterval(-86_400))
            await gmail.seedInbox(count: 3)
            store = try MailStore.openInMemoryForTesting()
            google = FakeGoogleSignIn(gmail: gmail, clock: clock, email: signInEmail, scope: scope)
            factory = DefaultGmailClientFactory(tokenStore: tokens, oauthClient: FakeGoogleSignIn.client,
                                                apiTransport: FakeGmailTransport(gmail), tokenTransport: google.transport,
                                                config: engineGmailConfig, clock: clock)
        }

        func engine() -> MailEngine {
            MailEngine(store: store, gmailFactory: factory, tokenStore: tokens, oauthClient: FakeGoogleSignIn.client,
                       configuration: EngineConfiguration(role: .app, appVersion: "0.0.0-test", gmail: engineGmailConfig,
                                                          clock: clock),
                       systemEvents: nil)
        }
    }

    private func reauthEvents(_ engine: MailEngine) async -> [AccountID] {
        engine.eventSink.finish()
        var accounts: [AccountID] = []
        for await event in engine.events {
            if case let .accountNeedsReauth(id) = event { accounts.append(id) }
        }
        return accounts
    }

    @Test func anAccountWithoutATokenWaitsForReauthorizationThenSyncs() async throws {
        let rig = try await Rig()
        let account = try rig.store.addAccount(email: "me@example.com", displayName: nil, scopes: [GmailScope.modify])
        let engine = rig.engine()
        await engine.start()
        #expect(await engine.runtime(for: account) == nil)
        #expect(try rig.store.accounts().first?.status == .needsReauth)
        #expect(engine.connectivity.current[account] == .needsReauth)

        try await engine.reauthorize(account, using: rig.google.flow())
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
            try await engine.reauthorize(account, using: rig.google.flow())
        }
        #expect(try rig.tokens.allAccounts().isEmpty)
    }

    @Test func signInRefusesAnyOtherRequestBeforeTheBrowserOpens() async throws {
        let rig = try await Rig()
        let engine = rig.engine()
        let browser = RecordingBrowser()
        let refused: [[String]] = [[GmailScope.readonly], [GmailScope.modify, "https://mail.google.com/"], []]
        for scopes in refused {
            await #expect(throws: OAuthError.denied("scope_mismatch"), "\(scopes)") {
                try await engine.addAccount(using: rig.google.flow(scopes: scopes, browser: browser), loginHint: nil)
            }
        }
        #expect(browser.opened.isEmpty)
        #expect(rig.google.transport.requests.isEmpty)
        #expect(try rig.tokens.allAccounts().isEmpty)
        #expect(try rig.store.accounts().isEmpty)

        let account = try await engine.addAccount(using: rig.google.flow(browser: browser), loginHint: nil)
        #expect(browser.opened.count == 1)
        #expect(account.grantedScopes == [GmailScope.modify])
    }

    @Test func aGrantWithoutModifyIsRefusedAndNothingIsStored() async throws {
        let rig = try await Rig(scope: GmailScope.readonly)
        let engine = rig.engine()
        await #expect(throws: OAuthError.insufficientScopes(missing: [GmailScope.modify])) {
            try await engine.addAccount(using: rig.google.flow(), loginHint: nil)
        }
        #expect(try rig.tokens.allAccounts().isEmpty)
        #expect(try rig.store.accounts().isEmpty)
    }

    @Test func aGrantThatLosesModifyNeedsSigningInAgain() async throws {
        let rig = try await Rig()
        let engine = rig.engine()
        let account = try await engine.addAccount(using: rig.google.flow(), loginHint: nil)
        let identity = "https://www.googleapis.com/auth/userinfo.email"

        await engine.handle(TokenEvent.scopesChanged(account: "me@example.com", scopes: [GmailScope.modify, identity]))
        #expect(try rig.store.accounts().first?.status == .active)
        #expect(engine.connectivity.current[account.id] == nil)

        await engine.handle(TokenEvent.scopesChanged(account: "me@example.com", scopes: [GmailScope.readonly]))
        let stored = try #require(try rig.store.accounts().first { $0.id == account.id })
        #expect(stored.status == .needsReauth)
        #expect(stored.grantedScopes == [GmailScope.readonly])
        #expect(engine.connectivity.current[account.id] == .needsReauth)
        #expect(await engine.runtime(for: account.id) == nil)
        #expect(await reauthEvents(engine) == [account.id])
    }

    @Test func removalSignsOutLocallyAndRemovesTheData() async throws {
        let rig = try await Rig()
        let engine = rig.engine()
        await engine.start()
        let account = try await engine.addAccount(using: rig.google.flow(), loginHint: "me@example.com")
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
