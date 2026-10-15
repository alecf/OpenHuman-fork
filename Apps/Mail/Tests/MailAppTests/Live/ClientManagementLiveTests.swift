import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanMail

private enum ManagedClients {
    static let workID = "555555555555-managedwork5.apps.googleusercontent.com"
    static let personalID = "666666666666-managedpers6.apps.googleusercontent.com"
    static let thirdID = "777777777777-managedthrd7.apps.googleusercontent.com"
    static let secrets = ["SYNTHETIC-W5-not-a-secret", "SYNTHETIC-P6-not-a-secret", "SYNTHETIC-T7-not-a-secret",
                          "SYNTHETIC-P6-rotated"]

    static func json(_ id: String, _ secret: String) -> Data {
        Data("""
            {"installed":{"client_id":"\(id)","client_secret":"\(secret)",
            "auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}}
            """.utf8)
    }
}

private final class MoveGoogle: Sendable {
    private final class Address: Sendable { let value = Mutex("") }
    let http = FakeHTTPTransport()
    private let next = Address()

    init() {
        let next = self.next
        http.on("POST", "/token") { _ in
            FakeHTTPTransport.json(200, ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh",
                                         "expires_in": 3600, "scope": GmailScope.modify, "token_type": "Bearer"])
        }
        http.on("GET", "/gmail/v1/users/me/profile") { _ in
            FakeHTTPTransport.json(200, ["emailAddress": next.value.withLock { $0 }, "messagesTotal": 0,
                                         "threadsTotal": 0, "historyId": "1"])
        }
    }

    func nextProfile(_ email: String) { next.value.withLock { $0 = email } }
}

private func consentClientID(_ url: URL?) -> String? {
    url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_id" }?.value }
}

@MainActor
@Test(.timeLimit(.minutes(2))) func clientsAreListedRemovedOnlyWhenUnusedReplacedInPlaceAndAccountsMovedBySigningIn()
    async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-clientmgmt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: home), processKind: .test,
                                                appVersion: "0.0.0-test"))
    let google = MoveGoogle()
    let clients = InMemoryOAuthClientStore()
    let tokens = InMemoryTokenStore()
    let calendarTokens = InMemoryTokenStore()
    let browser = RecordingBrowser()
    let manager = LiveAccountManager(
        store: store,
        dependencies: LiveAccountManager.Dependencies(
            environment: [:], storeDirectory: home, clientStore: clients, tokenStore: tokens, transport: google.http,
            makeReceiver: { AnsweringReceiver(browser: browser) }, browser: browser, clock: TestClock(),
            calendarTokenStore: calendarTokens))
    let (work, personal, third) = (ManagedClients.workID, ManagedClients.personalID, ManagedClients.thirdID)
    let workKey = OAuthClientConfig.registryKey(clientID: work)
    let personalKey = OAuthClientConfig.registryKey(clientID: personal)
    let thirdKey = OAuthClientConfig.registryKey(clientID: third)
    try await manager.importOAuthClient(json: ManagedClients.json(work, ManagedClients.secrets[0]))
    try await manager.importOAuthClient(json: ManagedClients.json(personal, ManagedClients.secrets[1]))

    let robin = try store.addAccount(email: "robin@example.com", displayName: nil, scopes: [GmailScope.modify])
    let sam = try store.addAccount(email: "sam@example.com", displayName: nil, scopes: [GmailScope.modify])
    try tokens.save(StoredToken(refreshToken: "synthetic-robin", grantedScopes: [GmailScope.modify], clientID: work),
                    account: "robin@example.com")
    try tokens.save(StoredToken(refreshToken: "synthetic-sam", grantedScopes: [GmailScope.modify], clientID: personal),
                    account: "sam@example.com")
    try calendarTokens.save(StoredToken(refreshToken: "synthetic-cal", grantedScopes: ["calendar-scope"],
                                        clientID: personal), account: "robin@example.com")

    var usage = await manager.oauthClientUsage()
    #expect(usage.map(\.id) == [workKey, personalKey])
    #expect(usage.map(\.accounts) == [[robin], [sam]] && usage.map(\.calendars) == [[], [robin]])
    #expect(usage.allSatisfy { $0.importedAt != nil })
    let shown = "\(usage)"
    for value in [work, personal] + ManagedClients.secrets { #expect(!shown.contains(value), "never an id or a secret") }

    let workShort = OAuthClientConfig.shortID(clientID: work)
    await #expect(throws: AccountSetupError(.refused, "…\(workShort) is still used by robin@example.com. Move it to "
        + "another client with Replace…, or sign it out, first.")) { try await manager.removeOAuthClient(workKey) }
    await #expect(throws: AccountSetupError.self) { try await manager.removeOAuthClient(personalKey) }
    #expect(Set(try clients.loadAll().map(\.config.registryKey)) == [workKey, personalKey])

    #expect(try await manager.inspectOAuthClientFile(ManagedClients.json(personal, ManagedClients.secrets[3]),
                                                     replacing: personalKey) == .sameClient)
    try await manager.replaceOAuthClient(personalKey, json: ManagedClients.json(personal, ManagedClients.secrets[3]))
    #expect(try clients.loadAll().first { $0.config.clientID == personal }?.config.clientSecret
            == ManagedClients.secrets[3])
    #expect(try clients.loadAll().count == 2, "replaced in place: still one item per client")
    await #expect(throws: AccountSetupError.self) {
        try await manager.replaceOAuthClient(personalKey, json: ManagedClients.json(work, ManagedClients.secrets[0]))
    }
    await #expect(throws: AccountSetupError.self) {
        _ = try await manager.inspectOAuthClientFile(Data("{}".utf8), replacing: personalKey)
    }
    #expect(try await manager.inspectOAuthClientFile(ManagedClients.json(third, ManagedClients.secrets[2]),
                                                     replacing: personalKey)
            == .differentClient(id: thirdKey, shortID: OAuthClientConfig.shortID(clientID: third)))
    #expect(try tokens.load(account: "sam@example.com")?.clientID == personal, "inspecting and replacing moved no one")

    try await manager.importOAuthClient(json: ManagedClients.json(third, ManagedClients.secrets[2]))
    google.nextProfile("sam@example.com")
    try await manager.moveAccount(sam, toOAuthClient: thirdKey)
    #expect(consentClientID(browser.urls.last) == third)
    #expect(try tokens.load(account: "sam@example.com")?.clientID == third)
    #expect(try store.setting(LiveAccountManager.clientKeySetting, scope: .account(sam)) == thirdKey)
    usage = await manager.oauthClientUsage()
    #expect(usage.first { $0.id == thirdKey }?.accounts == [sam])
    #expect(usage.first { $0.id == personalKey }?.accounts == [] && usage.first { $0.id == personalKey }?.calendars == [robin],
            "the calendar keeps its client until it connects again")
    await #expect(throws: AccountSetupError.self) { try await manager.moveAccount(sam, toOAuthClient: "0123456789abcdef0123456789abcdef") }

    google.nextProfile("someone-else@example.com")
    await #expect(throws: AccountSetupError.self) { try await manager.moveAccount(robin, toOAuthClient: thirdKey) }
    #expect(try tokens.load(account: "robin@example.com")?.clientID == work)

    await #expect(throws: AccountSetupError.self) { try await manager.removeOAuthClient(personalKey) }
    try calendarTokens.delete(account: "robin@example.com")
    try await manager.removeOAuthClient(personalKey)
    #expect(Set(try clients.loadAll().map(\.config.registryKey)) == [workKey, thirdKey])
    #expect(try clients.loadAll().first { $0.isDefault }?.config.clientID == work, "the default stays")
    #expect(try tokens.load(account: "robin@example.com") != nil && tokens.load(account: "sam@example.com") != nil)
    #expect(await manager.oauthClients().map(\.id) == [workKey, thirdKey])
    #expect(!google.http.requests.contains { $0.url.path(percentEncoded: false).contains("revoke") })
}
