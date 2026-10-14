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
    let directory: URL
    let tokens: InMemoryTokenStore
    let browser = RecordingBrowser()
    let writeModeSwitch: LiveWriteModeSwitch
    let reopened: Counter
    let backend: LiveBackend
    let app: AppModel

    init(environment: [String: String] = [:], tokenScopes: [String]?, threads: Int = 4,
         grants: String = GmailScope.modify, switchOn: Bool? = nil) async throws {
        let choice = try LaunchSafeMode.environmentChoice(environment)
        corpus = FakeCorpus.make(threadCount: threads, now: Date())
        gmail = FakeGmail(accountEmail: corpus.account.email)
        await FakeGmailLaunch.seed(gmail, corpus: corpus)
        google = FakeGoogle(gmail: gmail, grantedScope: grants)
        let api = google.api
        for method in ["POST", "PUT", "DELETE"] {
            google.http.on(method, "/gmail/v1/") { try await api.send($0) }
            google.http.on(method, "/upload/gmail/v1/") { try await api.send($0) }
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-rung3-\(UUID().uuidString)")
        store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .test,
                                                appVersion: "0.0.0-test",
                                                changeNotificationName: "dev.openhuman.tests.rung3.\(UUID().uuidString)"))
        if let switchOn { try store.setSetting(LiveWriteModeSwitch.key, switchOn, scope: .global) }
        let launch = LaunchSafeMode.forRealAccounts(choice, allowsChanges: LiveWriteModeSwitch.read(store))
        let reopened = Counter()
        self.reopened = reopened
        writeModeSwitch = LiveWriteModeSwitch(store: store, launchSource: choice, reopen: { reopened.count += 1 })
        let email = corpus.account.email
        tokens = InMemoryTokenStore()
        if let tokenScopes {
            _ = try store.addAccount(email: email, displayName: nil, scopes: tokenScopes)
            try tokens.save(StoredToken(refreshToken: "synthetic-refresh", grantedScopes: tokenScopes,
                                        clientID: SyntheticClient.clientID), account: email)
        }
        let browser = self.browser
        backend = LiveBackend(
            safeMode: launch, store: store, writeModeSwitch: writeModeSwitch,
            accountDependencies: LiveAccountManager.Dependencies(
                environment: environment.merging(["OPENHUMAN_OAUTH_CLIENT_JSON": try SyntheticClient.writeJSON()]) { a, _ in a },
                storeDirectory: directory.appendingPathComponent("none"), tokenStore: tokens,
                transport: google.http, makeReceiver: { AnsweringReceiver(browser: browser) }, browser: browser,
                clock: SystemClock(), signInTimeout: .seconds(30)),
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
        google.http.requests.filter { $0.url.path() != "/token" && !isReadOnlyOnTheWire($0) }
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
        try? FileManager.default.removeItem(at: directory)
    }
    private var stopped = false
}

private let normal = ["OPENHUMAN_SAFE_MODE": "normal"]

@MainActor
private final class Counter {
    var count = 0
}

@MainActor
@Test(.timeLimit(.minutes(3))) func theDefaultLaunchIsWriteModeAndSignInAsksForExactlyModify() async throws {
    let f = try await RealLaunch(tokenScopes: nil)
    defer { Task { await f.stop() } }
    #expect(f.backend.safeMode == .normal && f.writeModeSwitch.launchSource == .setting && f.writeModeSwitch.allowsChanges)
    guard case .signIn(let signIn) = f.app.screen else {
        Issue.record("expected the sign-in screen")
        return
    }
    #expect(signIn.safeMode == .normal && !signIn.offersReadOnly && signIn.notice == nil)
    let runner = Task { await signIn.run() }
    defer { runner.cancel() }
    await eventually("client configured") { signIn.phase == .ready }
    signIn.signIn()
    await eventually("the write-mode session") { f.session != nil }
    let consent = try #require(f.browser.urls.first)
    let query = URLComponents(url: consent, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.first { $0.name == "scope" }?.value == GmailScope.modify)
    #expect(!query.contains { $0.name == "include_granted_scopes" })
    #expect(try f.tokens.load(account: f.corpus.account.email)?.grantedScopes == [GmailScope.modify])
    let environment = try #require(f.environment)
    #expect(f.session?.safeMode == .normal && environment.writeMode != nil && environment.status.isWriteMode)
    #expect(environment.status.safeModeText == nil, "no write-mode indicator (WRITE-MODE-CALM)")
    let row = WriteModeSettingModel(port: try #require(environment.writeModeSwitch))
    #expect(row.isOn && !row.isShown, "no read-only choice in Settings")
    #expect(f.gmailWrites.isEmpty, "signing in changed nothing in Gmail")
    await f.stop()

    let signedIn = try await RealLaunch(tokenScopes: [GmailScope.modify], threads: 1)
    defer { Task { await signedIn.stop() } }
    #expect(signedIn.session?.safeMode == .normal && signedIn.environment?.writeMode != nil)
    await signedIn.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aReadOnlyLaunchStaysReadOnlyEvenWithAWriteModeToken() async throws {
    for (environment, switchOn) in [([:], false), (["OPENHUMAN_SAFE_MODE": "read-only"], nil)] as [([String: String], Bool?)] {
        let f = try await RealLaunch(environment: environment, tokenScopes: [GmailScope.modify], switchOn: switchOn)
        defer { Task { await f.stop() } }
        #expect(f.backend.safeMode == .readOnly)
        let environment = try #require(f.environment)
        let session = try #require(f.session)
        #expect(session.safeMode == .readOnly && environment.writeMode == nil)
        #expect(environment.status.safeModeText == "Read-only" && !environment.status.isWriteMode)
        _ = try await f.openInbox()
        #expect(!environment.router.windowTitle.contains("Write mode"))
        let ref = try #require(try f.inboxRefs().first)

        let queued = try f.store.apply(.star([ref]), origin: .app)
        _ = try f.store.apply(.setReminder(ref, dueAt: Date().addingTimeInterval(-60), condition: .always), origin: .app)
        _ = try await session.engine.syncNow(session.account, reason: "test")
        let statuses = await session.engine.waitForOperations(queued.operationIDs, timeout: .seconds(2))
        #expect(statuses.values.allSatisfy { $0 == .pending }, "no drainer in read-only")
        #expect(try f.store.activeReminders(account: session.account, limit: 10).count == 1, "no reminder runner in read-only")

        let port = try #require(environment.commands)
        await #expect(throws: MailPortError.blockedBySafeMode) {
            _ = try await port.apply(.star([MailStoreAdapter.threadKey(ref)]))
        }
        await #expect(throws: EngineError.self) { _ = try await session.engine.perform(.star([ref]), origin: .app) }
        await #expect(throws: GmailError.self) {
            try await session.api.batchModifyMessages(ids: ["m1"], add: ["STARRED"], remove: [])
        }
        #expect(f.gmailWrites.isEmpty, "Gmail saw reads only")
        await f.stop()
    }
}

@MainActor
@Test(.timeLimit(.minutes(3))) func writeModeStartsAtOnceThenAStarAndItsUndoReachGmail() async throws {
    let f = try await RealLaunch(environment: normal, tokenScopes: [GmailScope.modify])
    defer { Task { await f.stop() } }
    #expect(f.backend.safeMode == .normal)
    let environment = try #require(f.environment, "the mail window comes up at once, no sheet")
    let session = try #require(f.session)
    #expect(session.safeMode == .normal && !f.app.openedReadOnly)
    #expect(environment.writeMode != nil && environment.status.isWriteMode)
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
    #expect(!window.windowTitle.contains("Write mode"), "no title prefix (WRITE-MODE-CALM)")
    await f.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aReadOnlyTokenAsksToSignInAgainToAllowChanges() async throws {
    let f = try await RealLaunch(environment: normal, tokenScopes: [GmailScope.readonly])
    defer { Task { await f.stop() } }
    guard case .signIn(let signIn) = f.app.screen else {
        Issue.record("expected the sign-in screen")
        return
    }
    #expect(signIn.notice == LiveBackend.writeAccessNotice)
    #expect(signIn.notice?.hasPrefix("To make changes, sign in again") == true && signIn.notice?.contains("gmail.") == false,
            "user words, no scope names")
    #expect(signIn.safeMode == .normal && signIn.offersReadOnly)
    #expect(signIn.loginHint == f.corpus.account.email)
    #expect(f.session == nil && f.gmailWrites.isEmpty)
    let runner = Task { await signIn.run() }
    defer { runner.cancel() }
    await eventually("client configured") { signIn.phase == .ready }
    signIn.signIn()
    await eventually("the write-mode session") { f.session != nil }
    let consent = try #require(f.browser.urls.first)
    let query = URLComponents(url: consent, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.first { $0.name == "scope" }?.value == GmailScope.modify)
    #expect(!query.contains { $0.name == "include_granted_scopes" })
    #expect(try f.tokens.load(account: f.corpus.account.email)?.grantedScopes == [GmailScope.modify])
    #expect(try f.store.accounts().first?.grantedScopes == [GmailScope.modify])
    #expect(f.session?.safeMode == .normal && f.environment?.writeMode != nil)
    await f.stop()

    let broad = try await RealLaunch(environment: normal, tokenScopes: [GmailScope.readonly],
                                     grants: "\(GmailScope.modify) https://mail.google.com/")
    defer { Task { await broad.stop() } }
    await #expect(throws: AccountSetupError.self) { _ = try await broad.backend.accounts.addAccount(loginHint: nil) }
    #expect(try broad.tokens.load(account: broad.corpus.account.email)?.grantedScopes == [GmailScope.readonly])
    #expect(LiveAccountManager.setupError(OAuthError.insufficientScopes(missing: [GmailScope.modify])).message
        .contains("gmail.modify"))
    await broad.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aReadOnlyTokenInWriteModeOpensReadOnlyWithoutSigningIn() async throws {
    let f = try await RealLaunch(environment: normal, tokenScopes: [GmailScope.readonly], grants: GmailScope.readonly)
    defer { Task { await f.stop() } }
    guard case .signIn(let signIn) = f.app.screen else {
        Issue.record("expected the sign-in screen")
        return
    }
    signIn.openReadOnly()
    let session = try #require(f.session)
    let environment = try #require(f.environment)
    #expect(session.safeMode == .readOnly && environment.writeMode == nil && f.app.openedReadOnly)
    #expect(environment.status.safeModeText == "Read-only")
    _ = try await f.openInbox()
    let ref = try #require(try f.inboxRefs().first)
    let port = try #require(environment.commands)
    await #expect(throws: MailPortError.blockedBySafeMode) { _ = try await port.apply(.star([MailStoreAdapter.threadKey(ref)])) }
    await #expect(throws: EngineError.self) { _ = try await session.engine.perform(.star([ref]), origin: .app) }
    await #expect(throws: GmailError.self) { try await session.api.batchModifyMessages(ids: ["m1"], add: ["STARRED"], remove: []) }
    let queued = try f.store.apply(.star([ref]), origin: .app)
    let statuses = await session.engine.waitForOperations(queued.operationIDs, timeout: .seconds(2))
    #expect(statuses.values.allSatisfy { $0 == .pending }, "no drainer")
    #expect(f.browser.urls.isEmpty && f.gmailWrites.isEmpty)
    await f.stop()
}

@MainActor
@Test func theDenyListIsInTheWriteModeTransportStack() async throws {
    let google = FakeGoogle(gmail: FakeGmail(accountEmail: "robin@example.com"))
    let transport = SafeModeTransport.wrap(google.http, mode: .normal, grantedScopes: [GmailScope.modify], allowlist: nil)
    #expect(transport is DenyListTransport)
    let api = "https://gmail.googleapis.com/gmail/v1/users/me/"
    let denied: [(String, String)] = [
        ("DELETE", "messages/m1"), ("DELETE", "threads/t1"), ("POST", "messages/batchDelete"), ("DELETE", "labels/Label_1"),
        ("POST", "settings/filters"), ("POST", "settings/forwardingAddresses"), ("PUT", "settings/autoForwarding"),
        ("POST", "settings/delegates"), ("POST", "settings/sendAs"), ("PUT", "settings/vacation"), ("DELETE", "trash"),
    ]
    for (method, path) in denied {
        let request = HTTPRequest(method: method, url: URL(string: api + path)!, headers: [:], body: Data("{}".utf8))
        await #expect(throws: TransportError.blockedBySafeMode("\(method) /gmail/v1/users/me/\(path)")) {
            _ = try await transport.send(request)
        }
    }
    #expect(google.http.requests.isEmpty, "nothing reached Google")
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aBulkChangeOfAnySizeGoesAtOnceAndOneUndoReversesItInGmail() async throws {
    let f = try await RealLaunch(environment: normal.merging(["OPENHUMAN_WRITE_BULK_LIMIT": "1"]) { a, _ in a },
                                 tokenScopes: [GmailScope.modify], threads: 3)
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
    let f = try await RealLaunch(environment: normal.merging(["OPENHUMAN_WRITE_RECIPIENT_LIMIT": "1"]) { a, _ in a },
                                 tokenScopes: [GmailScope.modify], threads: 2)
    defer { Task { await f.stop() } }
    let environment = try #require(f.environment)
    let window = try await f.openInbox()
    let settings = try #require(environment.settings)
    #expect(try await settings.get(WriteModeSession.confirmEverySend) == false, "off by default")
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
@Test(.timeLimit(.minutes(3))) func writeModeShowsNoIndicatorEvenForARealAccount() async throws {
    let f = try await RealLaunch(environment: normal, tokenScopes: [GmailScope.modify])
    defer { Task { await f.stop() } }
    let environment = try #require(f.environment)
    let status = environment.status
    #expect(environment.writeMode != nil && status.isWriteMode)
    #expect(status.safeModeText == nil && status.safeModeDetail == nil && status.safeModeHelp == nil)
    #expect(!environment.router.windowTitle.contains("Write mode"))
    #expect(GeneralSettingsModel(environment: environment).showsWriteModeSending)
    #expect(GeneralSettingsModel.confirmEverySendNote.contains("Undo send"))
    await f.stop()

    let corpus = FakeCorpus.make(threadCount: 2, now: Date())
    let running = try FakeGmailLaunch.makeSession(safeMode: .normal, store: try MailStore.openInMemoryForTesting(),
                                                  gmail: FakeGmail(accountEmail: corpus.account.email))
    let fake = running.session.environment
    #expect(fake.writeMode == nil && !fake.status.isWriteMode && fake.status.safeModeText == nil)
    #expect(!fake.router.windowTitle.contains("Write mode"))
    #expect(!GeneralSettingsModel(environment: fake).showsWriteModeSending)
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aDockLaunchWithTheSwitchOnIsWriteModeLikeTheVariable() async throws {
    let f = try await RealLaunch(tokenScopes: [GmailScope.modify], switchOn: true)
    defer { Task { await f.stop() } }
    #expect(f.backend.safeMode == .normal)
    let environment = try #require(f.environment, "the mail window comes up at once, no sheet")
    let session = try #require(f.session)
    #expect(session.safeMode == .normal && environment.writeMode != nil && environment.status.isWriteMode)
    #expect(environment.writeModeSwitch === f.writeModeSwitch && f.writeModeSwitch.writesNow)
    #expect(f.writeModeSwitch.launchSource == .setting && f.writeModeSwitch.allowsChanges)
    let window = try await f.openInbox()
    #expect(!window.windowTitle.contains("Write mode"), "no title prefix (WRITE-MODE-CALM)")
    let ref = try #require(try f.inboxRefs().first)
    let port = try #require(environment.commands)
    let token = try await port.apply(.star([MailStoreAdapter.threadKey(ref)]))
    await waitFor("STARRED in FakeGmail") { await f.starred(ref) }
    _ = try await port.undo(token)
    await waitFor("STARRED gone in FakeGmail") { await !f.starred(ref) }
    #expect(f.gmailWrites.allSatisfy { $0.method == "POST" && ($0.url.path().hasSuffix("/batchModify") || $0.url.path().hasSuffix("/modify")) })
    await f.stop()

    let old = try await RealLaunch(tokenScopes: [GmailScope.readonly], switchOn: true)
    defer { Task { await old.stop() } }
    guard case .signIn(let signIn) = old.app.screen else {
        Issue.record("expected the sign-in screen")
        return
    }
    #expect(signIn.notice == LiveBackend.writeAccessNotice && signIn.offersReadOnly)
    #expect(old.session == nil && old.gmailWrites.isEmpty)
    await old.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func theVariableKeepsPriorityOverTheSwitch() async throws {
    let cases: [([String: String], Bool?, SafeMode, WriteModeLaunchSource)] = [
        (["OPENHUMAN_SAFE_MODE": "read-only"], true, .readOnly, .environmentReadOnly),
        (normal, false, .normal, .environmentNormal),
        (["OPENHUMAN_SAFE_MODE": "Normal"], true, .readOnly, .environmentReadOnly),
        (["OPENHUMAN_SAFE_MODE": "read_only"], true, .readOnly, .environmentReadOnly),
        ([:], false, .readOnly, .setting),
        ([:], nil, .normal, .setting),
        (["OPENHUMAN_SAFE_MODE": "read-only"], nil, .readOnly, .environmentReadOnly),
    ]
    for (environment, switchOn, mode, source) in cases {
        let f = try await RealLaunch(environment: environment, tokenScopes: [GmailScope.modify], threads: 1, switchOn: switchOn)
        #expect(f.backend.safeMode == mode && f.session?.safeMode == mode, "\(environment) \(switchOn)")
        #expect(f.writeModeSwitch.launchSource == source && f.writeModeSwitch.writesNow == (mode == .normal))
        #expect((f.environment?.writeMode != nil) == (mode == .normal))
        if mode == .readOnly {
            let model = WriteModeSettingModel(port: f.writeModeSwitch)
            #expect(model.isOn == (switchOn ?? true))
            if source == .environmentReadOnly { #expect(model.status?.contains("keeps this launch read-only") == true) }
        }
        #expect(f.gmailWrites.isEmpty)
        await f.stop()
    }
}

@MainActor
@Test(.timeLimit(.minutes(3))) func theSwitchAsksBeforeOnAndTurnsOffAtOnce() async throws {
    let f = try await RealLaunch(tokenScopes: [GmailScope.modify], threads: 1, switchOn: false)
    defer { Task { await f.stop() } }
    let model = WriteModeSettingModel(port: try #require(f.environment?.writeModeSwitch))
    #expect(!model.isOn && model.isShown && !f.writeModeSwitch.writesNow)
    model.request(true)
    #expect(model.isConfirming && !model.isOn && !LiveWriteModeSwitch.read(f.store), "the sheet first, nothing saved")
    model.cancel()
    #expect(!model.isConfirming && !model.isOn && !LiveWriteModeSwitch.read(f.store) && f.reopened.count == 0)
    model.request(true)
    model.confirm()
    #expect(model.isOn && LiveWriteModeSwitch.read(f.store) && f.reopened.count == 1, "saved, then Mail reopens")
    await f.stop()

    let writing = try await RealLaunch(tokenScopes: [GmailScope.modify], threads: 1, switchOn: true)
    defer { Task { await writing.stop() } }
    let on = WriteModeSettingModel(port: try #require(writing.environment?.writeModeSwitch))
    #expect(on.isOn && !on.isShown && on.status == nil && writing.writeModeSwitch.writesNow)
    on.request(false)
    #expect(!on.isConfirming && !on.isOn && !LiveWriteModeSwitch.read(writing.store), "off at once, no sheet")
    #expect(writing.reopened.count == 1, "the writing window reopens read-only")
    #expect(try writing.tokens.load(account: writing.corpus.account.email)?.grantedScopes == [GmailScope.modify],
            "nothing revoked: the token stays")
    #expect(!writing.google.http.requests.contains { $0.url.path().contains("revoke") })
    await writing.stop()

    let forced = try await RealLaunch(environment: ["OPENHUMAN_SAFE_MODE": "read-only"], tokenScopes: [GmailScope.modify],
                                      threads: 1, switchOn: false)
    defer { Task { await forced.stop() } }
    let readOnly = WriteModeSettingModel(port: try #require(forced.environment?.writeModeSwitch))
    readOnly.request(true)
    readOnly.confirm()
    #expect(readOnly.isOn && LiveWriteModeSwitch.read(forced.store) && forced.reopened.count == 0,
            "saved for the next launch; the variable keeps this one read-only")
    #expect(forced.session?.safeMode == .readOnly)
    await forced.stop()

    let corpus = FakeCorpus.make(threadCount: 1, now: Date())
    let fake = try FakeGmailLaunch.makeSession(safeMode: .normal, store: try MailStore.openInMemoryForTesting(),
                                               gmail: FakeGmail(accountEmail: corpus.account.email))
    #expect(fake.session.environment.writeModeSwitch == nil, "FakeGmail never gets the switch")
}
