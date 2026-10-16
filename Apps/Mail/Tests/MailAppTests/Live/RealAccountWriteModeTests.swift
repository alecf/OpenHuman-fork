import Foundation
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailRender
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import OpenHumanSync
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

@MainActor
private func waitFor(_ what: String, timeout: Duration = .seconds(30), _ condition: () async -> Bool,
                     sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while await !condition() {
        if clock.now > deadline {
            Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private final class RealLaunch {
    let corpus: FakeCorpus
    let gmail: FakeGmail
    let google: FakeGoogle
    let store: MailStore
    private let temp = TemporaryDirectory("oh-rung3")
    let directory: URL
    let tokens: InMemoryTokenStore
    let browser = RecordingBrowser()
    let backend: LiveBackend
    let app: AppModel

    init(environment: [String: String] = [:], tokenScopes: [String]?, threads: Int = 4,
         grants: String = GmailScope.modify) async throws {
        corpus = FakeCorpus.make(threadCount: threads, now: Date())
        gmail = FakeGmail(accountEmail: corpus.account.email)
        await FakeGmailLaunch.seed(gmail, corpus: corpus)
        google = FakeGoogle(gmail: gmail, grantedScope: grants)
        let api = google.api
        for method in ["POST", "PUT", "DELETE"] {
            google.http.on(method, "/gmail/v1/") { try await api.send($0) }
            google.http.on(method, "/upload/gmail/v1/") { try await api.send($0) }
        }
        directory = temp.url
        store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .test,
                                                appVersion: "0.0.0-test",
                                                changeNotificationName: "dev.openhuman.tests.rung3.\(UUID().uuidString)"))
        let email = corpus.account.email
        tokens = InMemoryTokenStore()
        if let tokenScopes {
            _ = try store.addAccount(email: email, displayName: nil, scopes: tokenScopes)
            try tokens.save(StoredToken(refreshToken: "synthetic-refresh", grantedScopes: tokenScopes,
                                        clientID: SyntheticClient.clientID), account: email)
        }
        let browser = self.browser
        backend = LiveBackend(
            store: store,
            accountDependencies: LiveAccountManager.Dependencies(
                environment: environment.merging(["OPENHUMAN_OAUTH_CLIENT_JSON": try SyntheticClient.writeJSON()]) { a, _ in a },
                storeDirectory: directory.appendingPathComponent("none"), tokenStore: tokens,
                transport: google.http, makeReceiver: { AnsweringReceiver(browser: browser) }, browser: browser,
                clock: SystemClock(), signInTimeout: .seconds(30), developerClientFile: BuildFlavor.oauthClientFile),
            transports: LiveBackend.Transports(api: google.http, token: google.http),
            userAgent: "OpenHumanMail/test", pollInterval: .seconds(3600), makeSystemEvents: { AppSystemEvents.quiet() })
        app = AppModel(live: backend)
    }

    var session: SyncSession? { app.session }

    var environment: AppEnvironment? {
        if case .mail(let environment) = app.screen { return environment }
        return nil
    }

    var gmailWrites: [HTTPRequest] {
        google.http.requests.filter { $0.url.path() != "/token" && !isReadOnTheWire($0) }
    }

    func openInbox() async throws -> AppRouter {
        let environment = try #require(self.environment)
        let window = environment.router
        window.start()
        await eventually("the window's account") { window.active != nil }
        window.go(to: .system(.inbox))
        let rows = corpus.threads.count
        await eventually("inbox rows", timeout: .seconds(60)) { window.list?.rows.count == rows }
        return window
    }

    func inboxRefs() throws -> [ThreadRef] {
        let account = try #require(session).account
        return try store.threadPage(view: .system(account, .inbox), after: nil, limit: 50).items.map(\.ref)
    }

    func has(_ label: String, _ ref: ThreadRef) async -> Bool {
        for message in await gmail.messageIDs(inThread: ref.gmailThreadID.rawValue) where await gmail.labelIDs(ofMessage: message)?.contains(label) == true {
            return true
        }
        return false
    }

    func starred(_ ref: ThreadRef) async -> Bool { await has("STARRED", ref) }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        environment?.router.stop()
        await session?.stop()
        try? store.close()
        temp.cleanup()
    }
    private var stopped = false
}

@MainActor
@Test(.timeLimit(.minutes(3))) func signInAsksForExactlyModify() async throws {
    let f = try await RealLaunch(tokenScopes: nil)
    defer { Task { await f.stop() } }
    guard case .signIn(let signIn) = f.app.screen else {
        Issue.record("expected the sign-in screen")
        return
    }
    #expect(signIn.notice == nil)
    let runner = Task { await signIn.run() }
    defer { runner.cancel() }
    await eventually("client configured") { signIn.phase == .ready }
    #expect(signIn.screen.sentence == SignInModel.readySentence && signIn.screen.buttons == ["Sign in with Google"])
    let view = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/OpenHumanMailUI/Sources/MailUI/Onboarding/SignInView.swift"), encoding: .utf8)
    #expect(view.contains("static let accessText = \"Mail asks Gmail for permission to read and change your mail: archive, star, "))
    #expect(view.contains("It never asks to delete mail permanently or to change Gmail settings or filters."))
    #expect(!view.contains("modeText") && !view.lowercased().contains("read-only"), "one access text, no mode line")
    signIn.signIn()
    await eventually("the session") { f.session != nil }
    let consent = try #require(f.browser.urls.first)
    let query = URLComponents(url: consent, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.first { $0.name == "scope" }?.value == GmailScope.modify)
    #expect(!query.contains { $0.name == "include_granted_scopes" })
    #expect(try f.tokens.load(account: f.corpus.account.email)?.grantedScopes == [GmailScope.modify])
    let environment = try #require(f.environment)
    #expect(environment.isLiveAccount)
    #expect(f.gmailWrites.isEmpty, "signing in changed nothing in Gmail")
    await f.stop()

    let signedIn = try await RealLaunch(tokenScopes: [GmailScope.modify], threads: 1)
    defer { Task { await signedIn.stop() } }
    #expect(signedIn.environment?.isLiveAccount == true)
    await signedIn.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aRealAccountStartsAtOnceThenAStarAndItsUndoReachGmail() async throws {
    let f = try await RealLaunch(tokenScopes: [GmailScope.modify])
    defer { Task { await f.stop() } }
    let environment = try #require(f.environment, "the mail window comes up at once, no sheet")
    let session = try #require(f.session)
    #expect(environment.isLiveAccount)
    let window = try await f.openInbox()
    let ref = try #require(try f.inboxRefs().first)
    let key = MailStoreAdapter.threadKey(ref)
    #expect(await !f.starred(ref))

    let port = try #require(environment.commands)
    let token = try await port.apply(.star([key]))
    await waitFor("STARRED in FakeGmail") { await f.starred(ref) }
    _ = try await port.undo(token)
    await waitFor("STARRED gone in FakeGmail") { await !f.starred(ref) }
    let writes = f.gmailWrites
    #expect(writes.count >= 2)
    #expect(writes.allSatisfy { $0.method == "POST" && ($0.url.path().hasSuffix("/batchModify") || $0.url.path().hasSuffix("/modify")) },
            "label changes only: no send, no delete, no draft")

    _ = try await port.apply(.setReminder(key, dueAt: Date().addingTimeInterval(-60), kind: .always))
    await waitFor("the reminder fired") { (try? f.store.activeReminders(account: session.account, limit: 10).isEmpty) == true }
    #expect(!window.windowTitle.contains("Write mode"), "no title prefix")
    await f.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aReadOnlyTokenAsksToSignInAgainToAllowChanges() async throws {
    let f = try await RealLaunch(tokenScopes: [GmailScope.readonly])
    defer { Task { await f.stop() } }
    guard case .signIn(let signIn) = f.app.screen else {
        Issue.record("expected the sign-in screen")
        return
    }
    #expect(signIn.notice == LiveBackend.writeAccessNotice)
    #expect(signIn.notice?.hasPrefix("To make changes, sign in again") == true && signIn.notice?.contains("gmail.") == false,
            "user words, no scope names")
    #expect(signIn.loginHint == f.corpus.account.email)
    #expect(f.session == nil && f.gmailWrites.isEmpty)
    let runner = Task { await signIn.run() }
    defer { runner.cancel() }
    await eventually("client configured") { signIn.phase == .ready }
    #expect(signIn.screen.sentence == LiveBackend.writeAccessNotice && signIn.screen.buttons == ["Sign in with Google"],
            "signing in again is the only way in; nothing opens the account without it")
    #expect(f.session == nil)
    signIn.signIn()
    await eventually("the session") { f.session != nil }
    let consent = try #require(f.browser.urls.first)
    let query = URLComponents(url: consent, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.first { $0.name == "scope" }?.value == GmailScope.modify)
    #expect(!query.contains { $0.name == "include_granted_scopes" })
    #expect(try f.tokens.load(account: f.corpus.account.email)?.grantedScopes == [GmailScope.modify])
    #expect(try f.store.accounts().first?.grantedScopes == [GmailScope.modify])
    #expect(f.environment?.isLiveAccount == true)
    await f.stop()

    let broad = try await RealLaunch(tokenScopes: [GmailScope.readonly],
                                     grants: "\(GmailScope.modify) https://mail.google.com/")
    defer { Task { await broad.stop() } }
    await #expect(throws: AccountSetupError.self) { _ = try await broad.backend.accounts.addAccount(loginHint: nil) }
    #expect(try broad.tokens.load(account: broad.corpus.account.email)?.grantedScopes == [GmailScope.readonly])
    #expect(LiveAccountManager.setupError(OAuthError.insufficientScopes(missing: [GmailScope.modify])).message
        .contains("gmail.modify"))
    await broad.stop()
}

@MainActor
@Test func theDenyListIsInTheTransportStack() async throws {
    let wire = FakeHTTPTransport()
    let factory = DefaultGmailClientFactory(apiTransport: wire, config: GmailClientConfig(userAgent: "OpenHumanMail/test"),
                                            clock: SystemClock()) { _ in
        (StaticTokenProvider(token: "synthetic-access"), [GmailScope.modify])
    }
    let client = try factory.gmailClient(for: "robin@example.com")
    for escape in ["../messages/m1", "../threads/t1", "../labels/Label_1", "../../settings/filters/f1"] {
        do {
            try await client.deleteDraft(id: escape)
            Issue.record("\(escape) was sent")
        } catch GmailError.transport(.refusedByGuard) {
        } catch {
            Issue.record("\(escape): \(error)")
        }
    }
    #expect(wire.requests.isEmpty, "nothing reached Google")
    try? await client.deleteDraft(id: "r1")
    #expect(wire.requests.map { "\($0.method) \($0.url.path())" } == ["DELETE /gmail/v1/users/me/drafts/r1"],
            "a draft delete is one of the client's own writes and goes through")

    let transport = DenyListTransport(wrapping: wire)
    let api = "https://gmail.googleapis.com/gmail/v1/users/me/"
    let denied: [(String, String)] = [
        ("DELETE", "messages/m1"), ("DELETE", "threads/t1"), ("POST", "messages/batchDelete"), ("DELETE", "labels/Label_1"),
        ("POST", "settings/filters"), ("POST", "settings/forwardingAddresses"), ("PUT", "settings/autoForwarding"),
        ("POST", "settings/delegates"), ("POST", "settings/sendAs"), ("PUT", "settings/vacation"), ("DELETE", "trash"),
    ]
    for (method, path) in denied {
        let request = HTTPRequest(method: method, url: URL(string: api + path)!, headers: [:], body: Data("{}".utf8))
        await #expect(throws: TransportError.refusedByGuard("\(method) /gmail/v1/users/me/\(path)")) {
            _ = try await transport.send(request)
        }
    }
    #expect(wire.requests.count == 1, "nothing more reached Google")
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aBulkChangeOfAnySizeGoesAtOnceAndOneUndoReversesItInGmail() async throws {
    let f = try await RealLaunch(environment: ["OPENHUMAN_WRITE_BULK_LIMIT": "1"], tokenScopes: [GmailScope.modify], threads: 3)
    defer { Task { await f.stop() } }
    let environment = try #require(f.environment)
    let window = try await f.openInbox()
    let refs = try f.inboxRefs()
    #expect(refs.count == 3)
    var before: [Bool] = []
    for ref in refs { before.append(await f.starred(ref)) }
    let changing = before.filter { !$0 }.count
    #expect(changing > 0)

    #expect(await environment.actions.run(.checkAll, source: .keyboard, host: window))
    #expect(await environment.actions.run(.toggleStar, source: .keyboard, host: window))
    for ref in refs { await waitFor("starred") { await f.starred(ref) } }
    let undo = try #require(environment.undo)
    let entry = try #require(undo.stack.last)
    #expect(undo.stack.count == 1 && entry.threads.count == changing, "one entry for the batch")
    #expect(String(localized: entry.title) == (changing == 1 ? "Starred" : "Starred \(changing) conversations"))
    #expect(await environment.actions.run(.undo, source: .keyboard, host: window))
    for (index, ref) in refs.enumerated() {
        await waitFor("as before") { await f.starred(ref) == before[index] }
    }

    let port = try #require(environment.commands)
    _ = try await port.apply(.markDone(refs.map(MailStoreAdapter.threadKey)))
    for ref in refs { await waitFor("out of the inbox in FakeGmail") { await !f.has("INBOX", ref) } }
    #expect(!f.gmailWrites.contains { $0.method == "DELETE" })
    await f.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aSendGoesStraightToItsUndoWindowWhateverTheRecipients() async throws {
    let f = try await RealLaunch(environment: ["OPENHUMAN_WRITE_RECIPIENT_LIMIT": "1"], tokenScopes: [GmailScope.modify],
                                 threads: 2)
    defer { Task { await f.stop() } }
    let environment = try #require(f.environment)
    let window = try await f.openInbox()
    let settings = try #require(environment.settings)
    #expect(try await settings.get(SendSettings.confirmEverySend) == false, "off by default")
    let compose = environment.compose
    compose.timing = ComposeTiming(autosaveDelay: .milliseconds(1), discardWindow: .milliseconds(1))
    func sent() async -> Int { Set(await f.gmail.deliveries().map(\.sentMessageID)).count }

    func message(_ to: String, _ subject: String) async throws -> ComposeSession {
        let session = try #require(compose.openNew(placement: .modal))
        session.to.text = to
        session.subject = subject
        session.updateBody(RichTextDocument(blocks: [.paragraph([.text("Synthetic body.", [])])]))
        await eventually("saved") { session.draftKey != nil && session.saveState == .saved }
        return session
    }

    try await settings.set(AppSettings.undoSendSeconds, 30)
    let first = try await message("dana@example.org, sam@example.org, kim@example.org,", "Synthetic one")
    #expect(await environment.actions.run(.send, source: .keyboard, host: first))
    await eventually("the undo toast") { environment.notices.toasts.contains { $0.message.hasPrefix("Sending to ") } }
    #expect(first.sendConfirmation == nil, "no card")
    #expect(await environment.actions.run(.undo, source: .keyboard, host: window))
    await eventually("the composer is back") { first.isOpen }
    #expect(await sent() == 0 && !f.gmailWrites.contains { $0.url.path().hasSuffix("/send") }, "nothing went out")

    try await settings.set(AppSettings.undoSendSeconds, 0)
    #expect(await environment.actions.run(.send, source: .keyboard, host: first))
    await waitFor("delivered") { await sent() == 1 }
    #expect(first.sendConfirmation == nil)
    #expect(await f.gmail.deliveries().count == 3, "each recipient once, the message once")
    #expect(!f.gmailWrites.contains { $0.method == "DELETE" && !$0.url.path().contains("/drafts/") })
    await f.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aRealAccountShowsNoModeIndicator() async throws {
    let f = try await RealLaunch(tokenScopes: [GmailScope.modify])
    defer { Task { await f.stop() } }
    let environment = try #require(f.environment)
    #expect(environment.isLiveAccount)
    #expect(!environment.router.windowTitle.contains("Write mode") && !environment.router.windowTitle.contains("Read-only"))
    #expect(GeneralSettingsModel(environment: environment).showsConfirmBeforeSending)
    #expect(GeneralSettingsModel.confirmEverySendNote.contains("Undo send"))
    await f.stop()

    let corpus = FakeCorpus.make(threadCount: 2, now: Date())
    let running = try FakeGmailLaunch.makeSession(store: try MailStore.openInMemoryForTesting(),
                                                  gmail: FakeGmail(accountEmail: corpus.account.email))
    let fake = running.session.environment
    #expect(!fake.isLiveAccount)
    #expect(!fake.router.windowTitle.contains("Write mode") && !fake.router.windowTitle.contains("Read-only"))
    #expect(!GeneralSettingsModel(environment: fake).showsConfirmBeforeSending)
}
