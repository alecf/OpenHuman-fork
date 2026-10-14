import Foundation
import MailFakes
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanMail

private func synthetic(_ scopes: [String] = [GmailScope.readonly]) -> StoredToken {
    StoredToken(refreshToken: "synthetic-refresh", grantedScopes: scopes, clientID: SyntheticClient.clientID)
}

private func manager(store: MailStore, tokens: InMemoryTokenStore, transport: FakeHTTPTransport) throws -> LiveAccountManager {
    LiveAccountManager(
        safeMode: .readOnly, store: store,
        dependencies: LiveAccountManager.Dependencies(
            environment: ["OPENHUMAN_OAUTH_CLIENT_JSON": try SyntheticClient.writeJSON()],
            storeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("oh-none-\(UUID().uuidString)"), tokenStore: tokens, transport: transport,
            makeReceiver: { AnsweringReceiver(browser: RecordingBrowser()) }, browser: RecordingBrowser(),
            clock: TestClock()))
}

@Test func signOutRemovesTheAccountsTokenRowsFilesAndDraftsOnly() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-signout-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .test,
                                                appVersion: "0.0.0-test"))
    let gone = try store.addAccount(email: "robin@example.com", displayName: nil, scopes: [GmailScope.readonly])
    let kept = try store.addAccount(email: "sam@example.com", displayName: nil, scopes: [GmailScope.readonly])
    let tokens = InMemoryTokenStore(["robin@example.com": synthetic(), "sam@example.com": synthetic()])
    let content = DraftContent(from: EmailAddress(email: "robin@example.com"), to: [], cc: [], bcc: [],
                               subject: "Synthetic", bodyHTML: "<p>Synthetic</p>", bodyText: "Synthetic", attachments: [])
    let draft = try store.createDraft(account: gone, mode: .new, replyTo: nil, content: content, origin: .user,
                                      reviewState: .none, agentNote: nil, extraHeaders: [:]).rawValue
    let files = FileManager.default
    func attachment(_ account: AccountID) -> URL {
        store.location.attachmentsDirectory.appendingPathComponent(String(account.rawValue), isDirectory: true)
    }
    for account in [gone, kept] {
        try files.createDirectory(at: attachment(account).appendingPathComponent("m1"), withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: attachment(account).appendingPathComponent("m1/file.bin"))
    }
    let draftFolder = store.location.draftsDirectory.appendingPathComponent(draft, isDirectory: true)
    try files.createDirectory(at: draftFolder, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: draftFolder.appendingPathComponent("draft.json"))
    let transport = FakeHTTPTransport()

    try await manager(store: store, tokens: tokens, transport: transport).remove(gone)

    #expect(try tokens.load(account: "robin@example.com") == nil)
    #expect(try tokens.load(account: "sam@example.com") != nil)
    #expect(try store.accounts().map(\.id) == [kept])
    #expect(!files.fileExists(atPath: attachment(gone).path))
    #expect(files.fileExists(atPath: attachment(kept).appendingPathComponent("m1/file.bin").path))
    #expect(!files.fileExists(atPath: draftFolder.path))
    #expect(transport.requests.isEmpty, "sign-out never contacts Google (no revocation, no Gmail call)")
    await #expect(throws: AccountSetupError.self) {
        try await manager(store: store, tokens: tokens, transport: transport).remove(gone)
    }
}

@MainActor
private func signedInApp(google: FakeGoogle, store: MailStore, tokens: InMemoryTokenStore, browser: RecordingBrowser,
                         email: String) async throws -> (AppModel, LiveBackend) {
    let backend = liveBackend(google: google, store: store, tokens: tokens, browser: browser,
                              clientPath: try SyntheticClient.writeJSON())
    let app = AppModel(live: backend)
    guard case .signIn(let signIn) = app.screen else {
        Issue.record("expected the sign-in screen")
        return (app, backend)
    }
    let runner = Task { await signIn.run() }
    defer { runner.cancel() }
    await eventually("client configured") { signIn.phase == .ready }
    signIn.loginHint = email
    signIn.signIn()
    await eventually("mail window") { if case .mail = app.screen { return true }; return false }
    return (app, backend)
}

@MainActor
@Test(.timeLimit(.minutes(2))) func signingOutTheLastAccountFromSettingsReturnsToSignIn() async throws {
    let corpus = FakeCorpus.make(threadCount: 10, now: Date())
    let gmail = FakeGmail(accountEmail: corpus.account.email)
    await FakeGmailLaunch.seed(gmail, corpus: corpus)
    let google = FakeGoogle(gmail: gmail)
    let tokens = InMemoryTokenStore()
    let store = try MailStore.openInMemoryForTesting()
    let (app, _) = try await signedInApp(google: google, store: store, tokens: tokens, browser: RecordingBrowser(),
                                         email: corpus.account.email)
    guard case .mail(let environment) = app.screen, let session = app.session else { return }
    #expect(environment.accounts != nil, "the live window can manage accounts (Settings › Accounts)")
    let account = session.account
    #expect(try tokens.load(account: corpus.account.email) != nil)

    let settings = AccountsSettingsModel(environment: environment)
    await settings.askToRemove(account)
    await settings.confirmRemoval()?.value

    #expect(settings.errorMessage == nil)
    #expect(try tokens.allAccounts().isEmpty)
    #expect(try store.accounts().isEmpty)
    guard case .signIn(let signIn) = app.screen else {
        Issue.record("expected the sign-in screen after the last account signed out")
        return
    }
    #expect(signIn.notice == AppModel.signedOutNotice)
    #expect(app.session == nil)
    for request in google.http.requests where request.url.path(percentEncoded: false) != "/token" {
        #expect(isReadOnlyOnTheWire(request))
    }
    #expect(!google.http.requests.contains { $0.url.path(percentEncoded: false).contains("revoke") })
}

@MainActor
@Test(.timeLimit(.minutes(2))) func signInAgainAndTheShortNameWorkInTheLiveWindow() async throws {
    let corpus = FakeCorpus.make(threadCount: 5, now: Date())
    let gmail = FakeGmail(accountEmail: corpus.account.email)
    await FakeGmailLaunch.seed(gmail, corpus: corpus)
    let google = FakeGoogle(gmail: gmail)
    let tokens = InMemoryTokenStore()
    let browser = RecordingBrowser()
    let store = try MailStore.openInMemoryForTesting()
    let (app, _) = try await signedInApp(google: google, store: store, tokens: tokens, browser: browser,
                                         email: corpus.account.email)
    guard case .mail(let environment) = app.screen, let session = app.session,
          let accounts = environment.accounts else { return }
    defer { Task { await session.stop() } }

    try await accounts.reauthorize(session.account)
    #expect(browser.urls.count == 2, "a second consent page for the same account")
    let consent = try #require(browser.urls.last)
    let query = URLComponents(url: consent, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.first { $0.name == "scope" }?.value == GmailScope.readonly)
    #expect(query.first { $0.name == "login_hint" }?.value == corpus.account.email)
    #expect(try tokens.load(account: corpus.account.email)?.grantedScopes == [GmailScope.readonly])

    try await accounts.setAlias(session.account, "  Work  ")
    #expect(try store.accounts().first?.alias == "Work")
    try await accounts.setAlias(session.account, nil)
    #expect(try store.accounts().first?.alias == nil)
}

@Test func signOutThatCannotDeleteTheFilesFailsAndCanBeRetried() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-signout-\(UUID().uuidString)")
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .test,
                                                appVersion: "0.0.0-test"))
    let files = FileManager.default
    let locked = store.location.attachmentsDirectory
    defer {
        try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? files.removeItem(at: directory)
    }
    let account = try store.addAccount(email: "robin@example.com", displayName: nil, scopes: [GmailScope.readonly])
    let folder = locked.appendingPathComponent(String(account.rawValue), isDirectory: true)
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("synthetic".utf8).write(to: folder.appendingPathComponent("file.bin"))
    let tokens = InMemoryTokenStore(["robin@example.com": synthetic()])
    let transport = FakeHTTPTransport()

    try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    await #expect(throws: AccountSetupError.self) {
        try await manager(store: store, tokens: tokens, transport: transport).remove(account)
    }
    #expect(try store.accounts().map(\.status) == [.removing])
    #expect(files.fileExists(atPath: folder.path))

    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    try await manager(store: store, tokens: tokens, transport: transport).remove(account)
    #expect(try store.accounts().isEmpty)
    #expect(!files.fileExists(atPath: folder.path))
    #expect(transport.requests.isEmpty)
}
