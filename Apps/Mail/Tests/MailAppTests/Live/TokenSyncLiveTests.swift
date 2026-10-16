import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanMail

private func liveManager(store: MailStore, tokens: any TokenStore, home: URL,
                         transport: FakeHTTPTransport) throws -> LiveAccountManager {
    LiveAccountManager(
        store: store,
        dependencies: LiveAccountManager.Dependencies(
            environment: ["OPENHUMAN_OAUTH_CLIENT_JSON": try SyntheticClient.writeJSON()], storeDirectory: home,
            tokenStore: tokens, transport: transport, makeReceiver: { AnsweringReceiver(browser: RecordingBrowser()) },
            browser: RecordingBrowser(), clock: TestClock(), developerClientFile: BuildFlavor.oauthClientFile))
}

@Test func theLiveManagerSharesAtLaunchFollowsTheSwitchAndSignOutKeepsTheSharedCopy() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-tokensync-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: home), processKind: .test,
                                                appVersion: "0.0.0-test"))
    let address = "robin@example.com"
    let account = try store.addAccount(email: address, displayName: nil, scopes: [GmailScope.modify])
    let own = InMemoryTokenStore([address: StoredToken(refreshToken: "synthetic-refresh", grantedScopes: [GmailScope.modify],
                                                       clientID: SyntheticClient.clientID)])
    let cloud = InMemorySharedGrantStore()
    let tokens = SyncedTokenStore(local: own, shared: cloud, device: InMemoryTokenDeviceStore())
    let transport = FakeHTTPTransport()

    let manager = try liveManager(store: store, tokens: tokens, home: home, transport: transport)
    #expect(cloud.peek(address)?.refreshToken == "synthetic-refresh", "the launch shared the existing sign-in")
    #expect(await manager.signInsSyncThroughICloudKeychain())
    #expect(cloud.peek(address)?.clientID == SyntheticClient.clientID)
    #expect(try own.load(account: address) != nil, "this Mac's own copy stays")
    #expect(await manager.signInSync(for: account) == .syncing)

    try await manager.setSignInSync(account, enabled: false)
    #expect(await manager.signInSync(for: account) == .notSyncing)
    #expect(cloud.peek(address) == nil)
    #expect(!(await manager.signInsSyncThroughICloudKeychain()), "nothing synchronizable is kept now")
    #expect(try own.load(account: address)?.refreshToken == "synthetic-refresh")
    _ = try liveManager(store: store, tokens: tokens, home: home, transport: transport)
    #expect(cloud.peek(address) == nil)

    try await manager.setSignInSync(account, enabled: true)
    #expect(await manager.signInSync(for: account) == .syncing)
    #expect(cloud.peek(address) != nil)

    try await manager.remove(account)
    #expect(try own.load(account: address) == nil && store.accounts().isEmpty)
    #expect(cloud.peek(address)?.refreshToken == "synthetic-refresh", "signing out of this Mac keeps the shared copy")
    #expect(transport.requests.isEmpty, "nothing here contacts Google")
}

@Test func signingOutWithTheSharedSignInRemovesItFromICloudKeychainToo() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-tokensync-3-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: home), processKind: .test,
                                                appVersion: "0.0.0-test"))
    let address = "robin@example.com"
    let account = try store.addAccount(email: address, displayName: nil, scopes: [GmailScope.modify])
    let own = InMemoryTokenStore([address: StoredToken(refreshToken: "synthetic-refresh", grantedScopes: [GmailScope.modify],
                                                       clientID: SyntheticClient.clientID)])
    let cloud = InMemorySharedGrantStore()
    let tokens = SyncedTokenStore(local: own, shared: cloud, device: InMemoryTokenDeviceStore())
    let transport = FakeHTTPTransport()
    let manager = try liveManager(store: store, tokens: tokens, home: home, transport: transport)
    #expect(await manager.signInSync(for: account) == .syncing)

    try await manager.removeIncludingSharedSignIn(account)
    #expect(try cloud.peek(address) == nil && own.load(account: address) == nil && store.accounts().isEmpty)
    #expect(transport.requests.isEmpty, "nothing here contacts Google")
}

@Test func anInstallThatNeverSignedInUsesTheSharedSignInWithOneRefreshAndNoBrowser() async throws {
    let address = "robin@example.com"
    let cloud = InMemorySharedGrantStore()
    try SyncedTokenStore(local: InMemoryTokenStore(), shared: cloud, device: InMemoryTokenDeviceStore())
        .save(StoredToken(refreshToken: "synthetic-refresh", grantedScopes: [GmailScope.modify],
                          clientID: SyntheticClient.clientID), account: address)

    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-tokensync-2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: home), processKind: .test,
                                                appVersion: "0.0.0-test"))
    let own = InMemoryTokenStore()
    let tokens = SyncedTokenStore(local: own, shared: cloud, device: InMemoryTokenDeviceStore())
    let google = FakeHTTPTransport()
    google.on("POST", "/token") { _ in
        FakeHTTPTransport.json(200, ["access_token": "synthetic-access", "expires_in": 3600,
                                     "scope": GmailScope.modify, "token_type": "Bearer"])
    }
    let browser = RecordingBrowser()
    let manager = LiveAccountManager(
        store: store,
        dependencies: LiveAccountManager.Dependencies(
            environment: ["OPENHUMAN_OAUTH_CLIENT_JSON": try SyntheticClient.writeJSON()], storeDirectory: home,
            tokenStore: tokens, transport: google, makeReceiver: { AnsweringReceiver(browser: browser) },
            browser: browser, clock: TestClock(), developerClientFile: BuildFlavor.oauthClientFile))

    #expect(await manager.sharedSignIns() == [address])
    let account = try await manager.useSharedSignIn(email: address)
    #expect(try store.accounts().map(\.id) == [account])
    #expect(google.requests.count == 1 && google.requests.first?.url.path == "/token")
    #expect(browser.urls.isEmpty, "no browser, no consent page, no redirect")
    #expect(try own.load(account: address) == nil, "this install keeps no refresh token of its own")
    #expect(cloud.peek(address)?.version == 1, "the shared copy is unchanged")
    #expect(await manager.sharedSignIns().isEmpty, "now an account here")
    #expect(await manager.signInSync(for: account) == .syncing)
}

@Test func aBuildThatCannotSyncSaysSignInsStayOnThisMac() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-tokensync-4-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: home), processKind: .test,
                                                appVersion: "0.0.0-test"))
    let address = "robin@example.com"
    let account = try store.addAccount(email: address, displayName: nil, scopes: [GmailScope.modify])
    let own = InMemoryTokenStore([address: StoredToken(refreshToken: "synthetic-refresh", grantedScopes: [GmailScope.modify],
                                                       clientID: SyntheticClient.clientID)])
    let tokens = SyncedTokenStore(local: own, shared: InMemorySharedGrantStore(available: false),
                                  device: InMemoryTokenDeviceStore())
    let manager = try liveManager(store: store, tokens: tokens, home: home, transport: FakeHTTPTransport())
    #expect(await manager.signInSync(for: account) == .unavailable)
    #expect(!(await manager.signInsSyncThroughICloudKeychain()))
}

@Test func withoutTokenSyncTheManagerHasNoSwitch() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-tokensync-off-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: home), processKind: .test,
                                                appVersion: "0.0.0-test"))
    let account = try store.addAccount(email: "sam@example.com", displayName: nil, scopes: [GmailScope.modify])
    let manager = try liveManager(store: store, tokens: InMemoryTokenStore(), home: home, transport: FakeHTTPTransport())
    #expect(await manager.signInSync(for: account) == nil)
    #expect(!(await manager.signInsSyncThroughICloudKeychain()))
    await #expect(throws: AccountSetupError.self) { try await manager.setSignInSync(account, enabled: false) }
}

@MainActor
@Test func theAppsTokenStoreIsTheSyncedOneOverTheThreeKeychainStores() {
    // Only types are checked: this test host is an app bundle, so calling a store would reach the real Keychain
    let tokens = CompositionRoot.syncedTokenStore(service: "dev.openhuman.mail.oauth.v1.home.0123456789abcdef",
                                                  accessGroup: nil)
    #expect(String(describing: type(of: tokens.local)) == "KeychainTokenStore")
    #expect(String(describing: type(of: tokens.shared)) == "KeychainSharedGrantStore")
    #expect(String(describing: type(of: tokens.device)) == "KeychainTokenDeviceStore")
}
