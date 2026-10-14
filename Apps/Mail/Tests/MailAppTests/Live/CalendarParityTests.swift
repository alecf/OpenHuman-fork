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

private enum ParityClients {
    static let workID = "333333333333-syntheticcal1.apps.googleusercontent.com"
    static let personalID = "444444444444-syntheticcal2.apps.googleusercontent.com"

    static func json(_ id: String) -> Data {
        Data("""
            {"installed":{"client_id":"\(id)","client_secret":"SYNTHETIC-\(id.prefix(4))-not-a-secret",
            "auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}}
            """.utf8)
    }
}

private let readScopes = CalendarScopes.requested(for: .readOnly)
private let writeScopes = CalendarScopes.requested(for: .normal)

private func form(_ body: Data?) -> [String: String] {
    guard let body, let text = String(data: body, encoding: .utf8) else { return [:] }
    var fields: [String: String] = [:]
    for pair in text.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        fields[kv[0]] = kv.count > 1 ? kv[1] : ""
    }
    return fields
}

private func query(_ url: URL?, _ name: String) -> String? {
    url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
}

private final class Shared<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
    var current: Value { value.withLock { $0 } }
    func set(_ next: Value) { value.withLock { $0 = next } }
}

@MainActor
private final class ParityHarness {
    static let robin = "robin@example.com"
    static let sam = "sam@example.org"
    let home: URL
    let store: MailStore
    let http = FakeHTTPTransport()
    let mailTokens = InMemoryTokenStore()
    let calendarTokens: any TokenStore
    let memoryCalendarTokens = InMemoryTokenStore()
    let browser = RecordingBrowser()
    let backend: LiveBackend
    let robinID: AccountID
    let samID: AccountID
    let granted = Shared(readScopes)
    let consentFails = Shared(false)

    init(launch: SafeMode = .readOnly, calendarStore: (any TokenStore)? = nil) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-calparity-\(UUID().uuidString)")
        store = try MailStore.open(StoreOptions(location: StoreLocation(directory: home), processKind: .test,
                                                appVersion: "0.0.0-test",
                                                changeNotificationName: "dev.openhuman.tests.calparity.\(UUID().uuidString)"))
        _ = try OAuthClientConfig.importClient(ParityClients.json(ParityClients.workID), storeDirectory: home)
        _ = try OAuthClientConfig.importClient(ParityClients.json(ParityClients.personalID), storeDirectory: home)
        let mailScope = launch == .normal ? GmailScope.modify : GmailScope.readonly
        robinID = try store.addAccount(email: Self.robin, displayName: nil, scopes: [mailScope])
        samID = try store.addAccount(email: Self.sam, displayName: nil, scopes: [mailScope])
        try mailTokens.save(StoredToken(refreshToken: "synthetic-mail-robin", grantedScopes: [mailScope],
                                        clientID: ParityClients.workID), account: Self.robin)
        try mailTokens.save(StoredToken(refreshToken: "synthetic-mail-sam", grantedScopes: [mailScope],
                                        clientID: ParityClients.personalID), account: Self.sam)
        try store.setSetting(LiveAccountManager.clientKeySetting,
                             OAuthClientConfig.registryKey(clientID: ParityClients.workID), scope: .account(robinID))
        try store.setSetting(LiveAccountManager.clientKeySetting,
                             OAuthClientConfig.registryKey(clientID: ParityClients.personalID), scope: .account(samID))
        calendarTokens = calendarStore ?? memoryCalendarTokens
        let granted = self.granted, consentFails = self.consentFails
        http.on("POST", "/token") { request in
            let fields = form(request.body)
            if fields["grant_type"] == "authorization_code", consentFails.current {
                return FakeHTTPTransport.json(400, ["error": "invalid_grant"])
            }
            let client = fields["client_id"] ?? ""
            return FakeHTTPTransport.json(200, ["access_token": "synthetic-access-\(client.prefix(4))",
                                                "refresh_token": "synthetic-refresh-\(client.prefix(4))",
                                                "expires_in": 3600, "scope": granted.current.joined(separator: " "),
                                                "token_type": "Bearer"])
        }
        http.on("GET", "/calendar/v3/") { _ in FakeHTTPTransport.json(200, ["items": [] as [Any]]) }
        http.on("POST", "/calendar/v3/freeBusy") { _ in FakeHTTPTransport.json(200, ["calendars": [:] as [String: Any]]) }
        let browser = self.browser
        backend = LiveBackend(
            safeMode: launch, store: store,
            accountDependencies: LiveAccountManager.Dependencies(
                environment: [:], storeDirectory: home, tokenStore: mailTokens,
                transport: http, makeReceiver: { AnsweringReceiver(browser: browser) }, browser: browser,
                clock: SystemClock(), signInTimeout: .seconds(30), calendarTokenStore: calendarTokens),
            transports: LiveBackend.Transports(api: http, token: http),
            userAgent: "OpenHumanMail/test", pollInterval: .seconds(3600), makeSystemEvents: { AppSystemEvents.quiet() })
    }

    func account(_ id: AccountID) throws -> AccountItem { try #require(backend.account(id)) }

    func model(_ id: AccountID, _ email: String) -> Account {
        Account(id: id, email: email, displayName: nil, alias: nil, health: .active)
    }

    func session(_ id: AccountID? = nil, writes: Bool = false) throws -> SyncSession {
        try backend.makeSession(for: try account(id ?? robinID), writes: writes)
    }

    func storeCalendarToken(_ email: String, client: String, scopes: [String], expired: Bool = false) throws {
        try calendarTokens.save(StoredToken(refreshToken: "synthetic-refresh-cal", accessToken: "synthetic-access-cal",
                                            accessTokenExpiry: Date().addingTimeInterval(expired ? -60 : 3600),
                                            grantedScopes: scopes, clientID: client), account: email)
    }

    var tokenRequests: [[String: String]] {
        http.requests.filter { $0.url.path(percentEncoded: false) == "/token" }.map { form($0.body) }
    }

    deinit { try? FileManager.default.removeItem(at: home) }
}

@MainActor
@Test(.timeLimit(.minutes(2))) func twoAccountsCalendarsUseTheirOwnClients() async throws {
    let h = try ParityHarness()
    let session = try h.session()
    let connections = try #require(session.calendarConnections)
    #expect(connections.routesByAccount)
    let robin = try #require(connections.calendarConnection(for: h.model(h.robinID, ParityHarness.robin)))
    let sam = try #require(connections.calendarConnection(for: h.model(h.samID, ParityHarness.sam)))
    let mailBefore = try (h.mailTokens.load(account: ParityHarness.robin), h.mailTokens.load(account: ParityHarness.sam))

    try await robin.connect(client: nil)
    #expect(query(h.browser.urls.last, "client_id") == ParityClients.workID)
    #expect(query(h.browser.urls.last, "login_hint") == ParityHarness.robin)
    try await sam.connect(client: nil)
    #expect(query(h.browser.urls.last, "client_id") == ParityClients.personalID)
    #expect(query(h.browser.urls.last, "login_hint") == ParityHarness.sam)
    for url in h.browser.urls.suffix(2) {
        #expect(query(url, "scope") == readScopes.joined(separator: " ") && query(url, "include_granted_scopes") == nil)
    }
    #expect(try h.calendarTokens.load(account: ParityHarness.robin)?.clientID == ParityClients.workID)
    #expect(try h.calendarTokens.load(account: ParityHarness.sam)?.clientID == ParityClients.personalID)

    let manager = h.backend.accounts
    #expect(manager.calendarClientKey(email: ParityHarness.robin) == OAuthClientConfig.registryKey(clientID: ParityClients.workID))
    #expect(manager.calendarClientKey(email: ParityHarness.sam) == OAuthClientConfig.registryKey(clientID: ParityClients.personalID))
    #expect(manager.calendarPinnedScopes(email: ParityHarness.sam) == readScopes)

    var states = sam.connectionStates().makeAsyncIterator()
    let samState = try #require(await states.next())
    #expect(samState.status == .connected && samState.clientShortID == OAuthClientConfig.shortID(clientID: ParityClients.personalID) && samState.problem == nil)

    try await sam.disconnect()
    #expect(try h.calendarTokens.load(account: ParityHarness.sam) == nil)
    #expect(try h.calendarTokens.load(account: ParityHarness.robin) != nil)
    #expect(try h.mailTokens.load(account: ParityHarness.robin) == mailBefore.0)
    #expect(try h.mailTokens.load(account: ParityHarness.sam) == mailBefore.1)

    try h.storeCalendarToken(ParityHarness.robin, client: ParityClients.workID, scopes: readScopes, expired: true)
    try h.storeCalendarToken(ParityHarness.sam, client: ParityClients.personalID, scopes: readScopes, expired: true)
    let relaunched = try h.session()
    let before = h.tokenRequests.count
    try await #require(relaunched.calendarConnections).resume([(id: h.robinID, email: ParityHarness.robin),
                                                              (id: h.samID, email: ParityHarness.sam)])
    let refreshes = Array(h.tokenRequests.dropFirst(before))
    #expect(refreshes.map { $0["grant_type"] } == ["refresh_token", "refresh_token"])
    #expect(refreshes.map { $0["client_id"] } == [ParityClients.workID, ParityClients.personalID])
    #expect(try h.mailTokens.load(account: ParityHarness.robin) == mailBefore.0, "Gmail's token is never refreshed here")
}

@MainActor
@Test(.timeLimit(.minutes(2))) func aGrantBeyondTheRecordedRequestIsRefusedPerAccount() async throws {
    let h = try ParityHarness()
    h.backend.accounts.recordCalendarConnect(email: ParityHarness.sam, clientID: ParityClients.personalID,
                                             requested: readScopes)
    try h.storeCalendarToken(ParityHarness.sam, client: ParityClients.personalID, scopes: writeScopes)
    try h.storeCalendarToken(ParityHarness.robin, client: ParityClients.workID, scopes: readScopes)
    let session = try h.session()
    let connections = try #require(session.calendarConnections)
    let sam = try #require(connections.calendarConnection(for: h.model(h.samID, ParityHarness.sam)))
    var states = sam.connectionStates().makeAsyncIterator()
    let refused = try #require(await states.next())
    #expect(refused.status == .needsReconnect && refused.problem == GoogleCalendarSession.broaderProblem)
    #expect(try h.calendarTokens.load(account: ParityHarness.sam) == nil, "the item is deleted, like Gmail's F4")
    #expect(connections.calendarProvider(for: h.model(h.samID, ParityHarness.sam)) == nil)
    #expect(connections.calendarProvider(for: h.model(h.robinID, ParityHarness.robin)) != nil, "robin's is untouched")

    let robinMail = try h.mailTokens.load(account: ParityHarness.robin)
    try h.storeCalendarToken(ParityHarness.robin, client: ParityClients.workID, scopes: readScopes, expired: true)
    h.granted.set(readScopes + [CalendarScope.events])
    let relaunched = try h.session()
    let robin = try #require(relaunched.calendarConnections?.calendarConnection(for: h.model(h.robinID, ParityHarness.robin)))
    try await #require(relaunched.calendarConnections).resume([(id: h.robinID, email: ParityHarness.robin)])
    #expect(try h.calendarTokens.load(account: ParityHarness.robin) == nil)
    var robinStates = robin.connectionStates().makeAsyncIterator()
    let robinState = try #require(await robinStates.next())
    #expect(robinState.status == .needsReconnect && robinState.problem == GoogleCalendarSession.broaderProblem)
    #expect(try h.mailTokens.load(account: ParityHarness.robin) == robinMail)
}

@MainActor
@Test(.timeLimit(.minutes(2))) func eachAccountsProviderIsItsOwnAndTheModuleRunsForAny() throws {
    let h = try ParityHarness()
    try h.storeCalendarToken(ParityHarness.sam, client: ParityClients.personalID, scopes: readScopes)
    let session = try h.session()
    #expect(session.environment.modules.modules.contains(.calendar))
    let connections = try #require(session.environment.calendarConnections)
    #expect(connections.routesByAccount)
    #expect(connections.calendarProvider(for: h.model(h.robinID, ParityHarness.robin)) == nil)
    let samProvider = try #require(connections.calendarProvider(for: h.model(h.samID, ParityHarness.sam)))
    #expect(samProvider.info.account == ParityHarness.sam)
    let sidebar = try #require(session.environment.calendarSidebar)
    #expect(sidebar.routesByAccount)
}

@MainActor
@Test(.timeLimit(.minutes(2))) func creatingIsWriteModeOnlyForEveryAccount() throws {
    let write = try ParityHarness(launch: .normal)
    try write.storeCalendarToken(ParityHarness.sam, client: ParityClients.personalID, scopes: writeScopes)
    let writing = try write.session(writes: true)
    let samWrite = try #require(writing.calendarConnections?.calendarProvider(for: write.model(write.samID, ParityHarness.sam)))
    #expect(samWrite.info.createRefusal == nil)

    let read = try ParityHarness()
    try read.storeCalendarToken(ParityHarness.sam, client: ParityClients.personalID, scopes: readScopes)
    let reading = try read.session()
    let samRead = try #require(reading.calendarConnections?.calendarProvider(for: read.model(read.samID, ParityHarness.sam)))
    #expect(samRead.info.createRefusal == "Read-only safe mode: Mail never creates calendar events.")
}

@MainActor
@Test(.timeLimit(.minutes(2))) func aCalendarFailureLeavesBothGmailTokensIntact() async throws {
    let h = try ParityHarness()
    h.consentFails.set(true)
    let mailBefore = try (h.mailTokens.load(account: ParityHarness.robin), h.mailTokens.load(account: ParityHarness.sam))
    let session = try h.session()
    let sam = try #require(session.calendarConnections?.calendarConnection(for: h.model(h.samID, ParityHarness.sam)))
    await #expect(throws: CalendarError.self) { try await sam.connect(client: nil) }
    #expect(try h.calendarTokens.load(account: ParityHarness.sam) == nil, "nothing stored")
    #expect(h.backend.accounts.calendarClientKey(email: ParityHarness.sam) == nil, "nothing recorded")
    #expect(try h.mailTokens.load(account: ParityHarness.robin) == mailBefore.0)
    #expect(try h.mailTokens.load(account: ParityHarness.sam) == mailBefore.1)
    #expect(try h.store.accounts().allSatisfy { $0.status == .active }, "both inboxes keep syncing")
}
