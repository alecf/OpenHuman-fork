import Foundation
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

private enum Clients {
    static let workID = "111111111111-syntheticwork1.apps.googleusercontent.com"
    static let personalID = "222222222222-syntheticpers2.apps.googleusercontent.com"
    static let workSecret = "SYNTHETIC-WORK-not-a-secret"
    static let personalSecret = "SYNTHETIC-PERSONAL-not-a-secret"

    static func json(_ id: String, _ secret: String) -> Data {
        Data("""
            {"installed":{"client_id":"\(id)","client_secret":"\(secret)",
            "auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}}
            """.utf8)
    }
}

private final class TwoAccountGoogle: Sendable {
    private final class Address: Sendable { let value = Mutex("") }

    let http = FakeHTTPTransport()
    private let next = Address()

    init() {
        let next = self.next
        http.on("POST", "/token") { request in
            let client = Self.form(request.body)["client_id"] ?? ""
            return FakeHTTPTransport.json(200, ["access_token": "access-\(client.prefix(12))",
                                                "refresh_token": "refresh-\(client.prefix(12))", "expires_in": 3600,
                                                "scope": GmailScope.modify, "token_type": "Bearer"])
        }
        http.on("GET", "/gmail/v1/users/me/profile") { _ in
            FakeHTTPTransport.json(200, ["emailAddress": next.value.withLock { $0 }, "messagesTotal": 0,
                                         "threadsTotal": 0, "historyId": "1"])
        }
    }

    func nextProfile(_ email: String) { next.value.withLock { $0 = email } }

    var tokenRequests: [[String: String]] {
        http.requests.filter { $0.url.path(percentEncoded: false) == "/token" }.map { Self.form($0.body) }
    }

    static func form(_ body: Data?) -> [String: String] {
        guard let body, let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            fields[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return fields
    }
}

private func consentClientID(_ url: URL?) -> String? {
    url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_id" }?.value }
}

@MainActor
@Test(.timeLimit(.minutes(2))) func twoAccountsSignInRefreshAndSignOutEachWithItsOwnClient() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-multiclient-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: home), processKind: .test,
                                                appVersion: "0.0.0-test"))
    let google = TwoAccountGoogle()
    let clients = InMemoryOAuthClientStore()
    let tokens = InMemoryTokenStore()
    let browser = RecordingBrowser()
    let clock = TestClock()
    let manager = LiveAccountManager(
        store: store,
        dependencies: LiveAccountManager.Dependencies(
            environment: [:], storeDirectory: home, clientStore: clients, tokenStore: tokens, transport: google.http,
            makeReceiver: { AnsweringReceiver(browser: browser) }, browser: browser, clock: clock))
    #expect(manager.currentClientStatus() == .missing)
    #expect(await manager.oauthClients().isEmpty)

    try await manager.importOAuthClient(json: Clients.json(Clients.workID, Clients.workSecret))
    let workKey = OAuthClientConfig.registryKey(clientID: Clients.workID)
    let personalKey = OAuthClientConfig.registryKey(clientID: Clients.personalID)
    #expect(manager.currentClientStatus() == .configured(source: .file))
    google.nextProfile("robin@example.com")
    let robin = try await manager.addAccount(loginHint: "robin@example.com")
    #expect(consentClientID(browser.urls.last) == Clients.workID)

    try await manager.importOAuthClient(json: Clients.json(Clients.personalID, Clients.personalSecret))
    let listed = await manager.oauthClients()
    #expect(listed.map(\.id) == [workKey, personalKey])
    #expect(listed.map(\.isDefault) == [true, false] && listed.map(\.isSelected) == [false, true])
    #expect(listed.map(\.shortID) == ["ticwork1", "ticpers2"])
    let shown = "\(listed) \(listed.map(\.title))"
    for value in [Clients.workID, Clients.personalID, Clients.workSecret, Clients.personalSecret] {
        #expect(!shown.contains(value), "the screens get short ids only, never an id or a secret")
    }
    google.nextProfile("sam@example.com")
    let sam = try await manager.addAccount(loginHint: "sam@example.com")
    #expect(consentClientID(browser.urls.last) == Clients.personalID)
    #expect(google.tokenRequests.map { $0["client_id"] } == [Clients.workID, Clients.personalID],
            "each code was exchanged with the client that asked for it")

    #expect(try tokens.load(account: "robin@example.com")?.clientID == Clients.workID)
    #expect(try tokens.load(account: "sam@example.com")?.clientID == Clients.personalID)
    #expect(try store.setting(LiveAccountManager.clientKeySetting, scope: .account(robin)) == workKey)
    #expect(try store.setting(LiveAccountManager.clientKeySetting, scope: .account(sam)) == personalKey)
    #expect(await manager.oauthClientShortID(for: robin) == "ticwork1")
    #expect(await manager.oauthClientShortID(for: sam) == "ticpers2")

    let accounts = try store.accounts()
    let robinItem = try #require(accounts.first { $0.id == robin })
    let samItem = try #require(accounts.first { $0.id == sam })
    #expect(try manager.client(for: samItem).clientID == Clients.personalID)
    let credentials = LiveBackend.credentials(tokenStore: tokens, accounts: manager, client: try manager.client(for: robinItem),
                                              transport: google.http, clock: clock, onEvent: { _ in })
    _ = try await credentials.tokenManager(for: "robin@example.com").accessToken(forceRefresh: true)
    _ = try await credentials.tokenManager(for: "sam@example.com").accessToken(forceRefresh: true)
    let refreshes = google.tokenRequests.suffix(2)
    #expect(refreshes.map { $0["grant_type"] } == ["refresh_token", "refresh_token"])
    #expect(refreshes.map { $0["client_id"] } == [Clients.workID, Clients.personalID])
    #expect(refreshes.map { $0["client_secret"] } == [Clients.workSecret, Clients.personalSecret])

    try await manager.selectOAuthClient(workKey)
    try tokens.delete(account: "sam@example.com")
    #expect(manager.ownClient(email: samItem.email, account: sam)?.clientID == Clients.personalID)
    await #expect(throws: AccountSetupError.self) { try await manager.selectOAuthClient("not-a-known-client") }

    try await manager.remove(robin)
    #expect(Set(try clients.loadAll().map(\.config.registryKey)) == [workKey, personalKey])
    #expect(try clients.loadAll().map(\.sync) == [.syncing, .syncing], "synchronizable by default")
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("oauth-client.json").path))
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("oauth-clients").path))
    #expect(await manager.oauthClients().count == 2)
    #expect(!google.http.requests.contains { $0.url.path(percentEncoded: false).contains("revoke") })
}

@MainActor
@Test(.timeLimit(.minutes(1))) func theSignInScreenShowsTheLiveClientsShortIDs() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-multiclient-ui-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let manager = LiveAccountManager(
        store: try MailStore.openInMemoryForTesting(),
        dependencies: LiveAccountManager.Dependencies(
            environment: [:], storeDirectory: home, tokenStore: InMemoryTokenStore(),
            transport: FakeHTTPTransport(), makeReceiver: { AnsweringReceiver(browser: RecordingBrowser()) },
            browser: RecordingBrowser(), clock: TestClock()))
    let model = SignInModel(accounts: manager)
    let runner = Task { await model.run() }
    defer { runner.cancel() }
    await eventually("needs a client") { model.phase == .needsClient }
    await model.importClient(json: Clients.json(Clients.workID, Clients.workSecret))
    await eventually("ready") { model.phase == .ready }
    #expect(model.clientLabel == "Google client …ticwork1 (default)" && !model.showsClientPicker)
    await model.importClient(json: Clients.json(Clients.personalID, Clients.personalSecret))
    await eventually("two clients") { model.clients.count == 2 }
    #expect(model.showsClientPicker && model.selectedClient?.shortID == "ticpers2")
    await model.selectClient(OAuthClientConfig.registryKey(clientID: Clients.workID))
    #expect(model.selectedClient?.shortID == "ticwork1")
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aLegacySingleClientFileStaysTheDefaultForAccountsWithoutTheirOwn() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-legacyclient-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let legacy = home.appendingPathComponent("oauth-client.json")
    try Clients.json(Clients.workID, Clients.workSecret).write(to: legacy)
    chmod(legacy.path, 0o600)
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: home), processKind: .test,
                                                appVersion: "0.0.0-test"))
    let clients = InMemoryOAuthClientStore()
    let manager = LiveAccountManager(
        store: store,
        dependencies: LiveAccountManager.Dependencies(
            environment: [:], storeDirectory: home, clientStore: clients, tokenStore: InMemoryTokenStore(),
            transport: FakeHTTPTransport(), makeReceiver: { AnsweringReceiver(browser: RecordingBrowser()) },
            browser: RecordingBrowser(), clock: TestClock()))
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(try clients.loadAll().map(\.isDefault) == [true] && clients.loadAll().map(\.sync) == [.syncing])
    #expect(manager.currentClientStatus() == .configured(source: .file))
    #expect(try manager.loadClient().clientID == Clients.workID)
    #expect(manager.ownClient(email: "legacy@example.com", account: nil) == nil)
    let legacyAccount = AccountItem(id: AccountID(1), email: "legacy@example.com", position: 0, status: .active, sendAs: [])
    #expect(try manager.client(for: legacyAccount).clientID == Clients.workID)
    try await manager.importOAuthClient(json: Clients.json(Clients.personalID, Clients.personalSecret))
    #expect(await manager.oauthClients().count == 2)
    #expect(try manager.client(for: legacyAccount).clientID == Clients.workID)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func anUnreadableKeychainNeverSendsTheSignInBackToSetup() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-keychainfix-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let legacy = home.appendingPathComponent("oauth-client.json")
    try Clients.json(Clients.workID, Clients.workSecret).write(to: legacy)
    chmod(legacy.path, 0o600)
    let clients = InMemoryOAuthClientStore()
    clients.failLoads(true)
    func manager(_ directory: URL) throws -> LiveAccountManager {
        LiveAccountManager(
            store: try MailStore.openInMemoryForTesting(),
            dependencies: LiveAccountManager.Dependencies(
                environment: [:], storeDirectory: directory, clientStore: clients, tokenStore: InMemoryTokenStore(),
                transport: FakeHTTPTransport(), makeReceiver: { AnsweringReceiver(browser: RecordingBrowser()) },
                browser: RecordingBrowser(), clock: TestClock()))
    }
    let upgraded = try manager(home)
    #expect(FileManager.default.fileExists(atPath: legacy.path))
    #expect(upgraded.currentClientStatus() == .configured(source: .file))
    #expect(try upgraded.loadClient().clientID == Clients.workID)

    let fresh = try manager(home.appendingPathComponent("fresh"))
    let model = SignInModel(accounts: fresh)
    let runner = Task { await model.run() }
    defer { runner.cancel() }
    await eventually("needs a client") { model.phase == .needsClient }
    await model.importClient(json: Clients.json(Clients.personalID, Clients.personalSecret))
    await eventually("ready to sign in") { model.phase == .ready && model.canSignIn }
    #expect(model.errorMessage == nil && !model.showsClientGuide)

    clients.failSaves(true)
    await model.importClient(json: Clients.json(Clients.workID, Clients.workSecret))
    #expect(model.errorMessage?.contains("Keychain error -25299") == true)
    #expect(model.errorMessage?.contains("isn't a Google sign-in client file") == false)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aClientThatCannotSyncSaysSoInOneLineAndTheReportListsWhereItIs() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-keychainreport-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: home), processKind: .test,
                                                appVersion: "0.0.0-test"))
    let clients = InMemoryOAuthClientStore(syncAvailable: false)
    let tokens = InMemoryTokenStore()
    let manager = LiveAccountManager(
        store: store,
        dependencies: LiveAccountManager.Dependencies(
            environment: [:], storeDirectory: home, clientStore: clients, tokenStore: tokens,
            transport: FakeHTTPTransport(), makeReceiver: { AnsweringReceiver(browser: RecordingBrowser()) },
            browser: RecordingBrowser(), clock: TestClock()))
    #expect(await manager.oauthClientImportNote() == nil)
    try await manager.importOAuthClient(json: Clients.json(Clients.workID, Clients.workSecret))
    #expect(await manager.oauthClientImportNote() == LiveAccountManager.clientNotSyncedNote)
    #expect(manager.currentClientStatus() == .configured(source: .file))

    _ = try store.addAccount(email: "robin@example.com", displayName: nil, scopes: [GmailScope.modify])
    try tokens.save(StoredToken(refreshToken: "synthetic-refresh-report", grantedScopes: [GmailScope.modify],
                                clientID: Clients.workID), account: "robin@example.com")
    let report = manager.keychainDiagnostics()
    let key = OAuthClientConfig.registryKey(clientID: Clients.workID)
    #expect(report.entries.contains(.init(subject: "client \(key.prefix(8))", local: true, synced: false, file: false)))
    #expect(report.entries.contains(.init(subject: "account 1", local: true, synced: false, file: false)))
    let text = "\(report)"
    for value in [Clients.workID, Clients.workSecret, "robin@example.com", "synthetic-refresh-report"] {
        #expect(!text.contains(value))
    }
}
