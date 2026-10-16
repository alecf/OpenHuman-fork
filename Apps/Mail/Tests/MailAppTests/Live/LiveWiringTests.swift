import Foundation
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailRender
import MailUI
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import OpenHumanSync
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

private let now = Date()

private func onDiskStore() throws -> (MailStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-app-\(UUID().uuidString)")
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .test,
                                                appVersion: "0.0.0-test"))
    return (store, directory)
}

private func isGET(_ request: HTTPRequest) -> Bool { request.method == "GET" }

func isReadOnTheWire(_ request: HTTPRequest) -> Bool {
    if request.method == "GET" { return true }
    guard request.method == "POST", request.url.path(percentEncoded: false) == "/batch/gmail/v1",
          let contentType = request.headers["Content-Type"],
          let boundary = contentType.components(separatedBy: "boundary=").last,
          let body = request.body, let text = String(data: body, encoding: .isoLatin1) else { return false }
    let parts = text.components(separatedBy: "--\(boundary)").dropFirst().filter { !$0.hasPrefix("--") }
    return !parts.isEmpty && parts.allSatisfy { part in
        let lines = part.components(separatedBy: "\r\n")
        guard let first = lines.first(where: { $0.contains(" /gmail/v1/") }) else { return false }
        return first.hasPrefix("GET ")
    }
}

@Test func connectivityMapsEngineStateSyncStateAndErrors() {
    let account = AccountID(1)
    func status(_ phase: SyncPhase, failures: Int = 0, error: String? = nil, success: Date? = nil) -> SyncStatus {
        SyncStatus(accountID: account, phase: phase, lastSuccessAt: success, backfillComplete: false,
                   consecutiveFailures: failures, lastError: error, pendingOperations: 0, failedOperations: 0)
    }
    func map(_ status: SyncStatus?, _ account: AccountStatus, _ engine: AccountConnectivity?) -> ConnectivityState {
        SyncSession.connectivityState(engine, status: status, accountStatus: account)
    }
    let online = AccountConnectivity.online(syncing: false, lastSyncAt: now)
    #expect(map(nil, .active, nil) == .online(syncing: true, lastSyncAt: nil))
    #expect(map(status(.new), .active, nil) == .online(syncing: true, lastSyncAt: nil))
    #expect(map(status(.incremental, success: now), .active, online) == .online(syncing: false, lastSyncAt: now))
    #expect(map(status(.incremental, success: now), .active, .online(syncing: true, lastSyncAt: now))
        == .online(syncing: false, lastSyncAt: now))
    #expect(map(status(.resyncRequired, success: now), .active, online) == .online(syncing: true, lastSyncAt: now))
    #expect(map(status(.incremental, failures: 2, error: "transport:not_connected", success: now), .active, online)
        == .offline(since: now))
    #expect(map(status(.incremental, failures: 1, error: "rate_limited"), .active, online) == .rateLimited(until: nil))
    #expect(map(status(.incremental, failures: 3, error: "server_503"), .active, online)
        == .syncFailing(code: "server_503", failures: 3, lastSyncAt: nil))
    let later = now.addingTimeInterval(120)
    #expect(map(status(.incremental, success: now), .active, .offline(since: later)) == .offline(since: later))
    #expect(map(status(.incremental, success: now), .active, .rateLimited(until: later)) == .rateLimited(until: later))
    #expect(map(status(.incremental), .active, .needsReauth) == .needsReauth)
    #expect(map(status(.incremental), .needsReauth, online) == .needsReauth)
    #expect(map(status(.incremental, success: now), .active, .ownedElsewhere(kind: "app", lastSyncAt: nil))
        == .syncFailing(code: "owned_elsewhere", failures: 0, lastSyncAt: now))
}

@MainActor
@Test(.timeLimit(.minutes(2))) func fakeGmailReadPathThroughTheAdapterSendsOnlyGETs() async throws {
    let corpus = FakeCorpus.make(threadCount: 60, now: now)
    let gmail = FakeGmail(accountEmail: corpus.account.email)
    await FakeGmailLaunch.seed(gmail, corpus: corpus)
    let (store, directory) = try onDiskStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let running = try FakeGmailLaunch.makeSession(store: store, gmail: gmail)
    let session = running.session
    let environment = session.environment
    await session.start()
    defer { Task { await session.stop() } }

    let data = environment.data
    let window = try await firstValue(data.threadWindow(.system(.inbox), account: session.account, limit: 100)) {
        $0.rows.count == 60
    }
    #expect(window.rows.map(\.subject) == corpus.threads.map(\.detail.subject))
    #expect(window.rows.map(\.messageCount) == corpus.threads.map(\.row.messageCount))

    let index = try #require(corpus.threads.indices.dropFirst(12).first { corpus.threads[$0].detail.messages.count >= 2 })
    let source = corpus.threads[index]
    let detail = try #require(try await firstValue(data.threadDetail(window.rows[index].id)))
    #expect(detail.subject == source.detail.subject)
    #expect(detail.messages.count == source.detail.messages.count)
    let message = try #require(detail.messages.last)
    let lastSource = try #require(source.detail.messages.last)
    let expected = try #require(source.bodies[lastSource.id])
    let body = try await firstValue(data.body(message.id)) { if case .available = $0 { true } else { false } }
    guard case .available(let content) = body else { return }
    let firstLine = try #require(expected.text?.split(separator: "\n").first.map(String.init))
    #expect(content.text?.contains(firstLine) == true)
    #expect((content.html != nil) == (expected.html != nil))

    let status = environment.status
    let follower = Task { await status.run() }
    defer { follower.cancel() }
    await eventually("synced status") { status.syncText(now: Date())?.hasPrefix("Synced") == true }

    #expect(!running.wire.requests.isEmpty)
    #expect(running.wire.requests.allSatisfy(isReadOnTheWire), "reading never writes")
    #expect(try store.operations(account: session.account, statuses: [], limit: 10).isEmpty)
}

private func isContentFetch(_ request: HTTPRequest) -> Bool {
    let path = request.url.path(percentEncoded: false)
    return path == "/batch/gmail/v1" || path.contains("/threads/") || path.contains("/messages/")
}

@MainActor
@Test(.timeLimit(.minutes(3))) func theBackfillCompletesAndASecondLaunchRefetchesNothing() async throws {
    let corpus = FakeCorpus.make(threadCount: 60, now: now)
    let gmail = FakeGmail(accountEmail: corpus.account.email)
    await FakeGmailLaunch.seed(gmail, corpus: corpus)
    let (store, directory) = try onDiskStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try FakeGmailLaunch.makeSession(store: store, gmail: gmail)
    let lines = first.session.environment.data.syncProgress()
    let seen = Task { () -> [String] in
        var all: [String] = []
        for await line in lines { all.append(contentsOf: line.values) }
        return all
    }
    defer { seen.cancel() }
    await first.session.start()
    await eventually("backfill complete", timeout: .seconds(90)) { first.session.backfillProgress?.stage == .complete }
    let progress = try #require(first.session.backfillProgress)
    #expect(progress.statusText == nil)
    #expect(progress.inboxTotal == 60 && progress.inboxSynced == 60)
    await first.session.stop()
    #expect(first.session.backfillProgress == nil, "a stopped engine leaves no progress line")
    seen.cancel()
    #expect(!(await seen.value).isEmpty, "the status area's stream carried the backfill line")
    #expect(try store.threadPage(view: .system(first.session.account, .inbox), after: nil, limit: 100).items.count == 60)
    #expect(first.wire.requests.contains(where: isContentFetch))
    #expect(first.wire.requests.allSatisfy(isReadOnTheWire))

    let second = try FakeGmailLaunch.makeSession(store: store, gmail: gmail)
    #expect(second.session.account == first.session.account)
    await second.session.start()
    await eventually("second launch ran", timeout: .seconds(60)) {
        second.wire.requests.contains { $0.url.path(percentEncoded: false).hasSuffix("/history") }
            && second.session.backfillProgress?.isRunning == false
    }
    await second.session.stop()
    #expect(second.wire.requests.filter(isContentFetch).isEmpty)
    #expect(second.wire.requests.allSatisfy(isReadOnTheWire))
    #expect(try store.threadPage(view: .system(second.session.account, .inbox), after: nil, limit: 100).items.count == 60)
}

@MainActor
@Test func theStatusAreaShowsTheBackfillLineOnlyWhileTheAccountIsHealthy() async throws {
    let account = AccountID(1)
    func model(_ state: ConnectivityState, _ line: String) throws -> StatusModel {
        let source = MailStoreAdapter(
            store: try MailStore.openInMemoryForTesting(),
            connectivity: { AsyncStream { $0.yield([account: state]); $0.finish() } },
            syncProgress: { AsyncStream { $0.yield([account: line]); $0.finish() } })
        return StatusModel(data: source)
    }
    let healthy = try model(.online(syncing: false, lastSyncAt: now), "Syncing 1,240 of 4,707")
    let followHealthy = Task { await healthy.run() }
    defer { followHealthy.cancel() }
    await eventually("progress line") { healthy.syncText(now: now) == "Syncing 1,240 of 4,707" }
    let offline = try model(.offline(since: nil), "Syncing 1 of 2")
    let followOffline = Task { await offline.run() }
    defer { followOffline.cancel() }
    await eventually("offline wins") { offline.syncText(now: now) == "Offline. Retrying." }
}

@MainActor
@Test(.timeLimit(.minutes(2))) func fakeGmailReadPathThroughTheWindowModels() async throws {
    let corpus = FakeCorpus.make(threadCount: 30, now: now)
    let gmail = FakeGmail(accountEmail: corpus.account.email)
    await FakeGmailLaunch.seed(gmail, corpus: corpus)
    let running = try FakeGmailLaunch.makeSession(store: try MailStore.openInMemoryForTesting(), gmail: gmail)
    let environment = running.session.environment
    await running.session.start()
    defer { Task { await running.session.stop() } }

    let window = MailWindowModel(environment: environment)
    window.start()
    await eventually("list rows") { window.list?.rows.count == 30 }
    let target = try #require(window.list?.rows.dropFirst(15).first { !$0.isUnread }, "a read conversation: opening it changes nothing")
    window.open(target.id)
    #expect(window.mode == .reader)
    await eventually("rendered body") {
        if case .rendered = window.reader?.messages.last?.body { return true }
        return false
    }
    #expect(running.wire.requests.allSatisfy(isReadOnTheWire), "reading never writes")
}

@MainActor
func liveBackend(google: FakeGoogle, store: MailStore, tokens: InMemoryTokenStore,
                 browser: RecordingBrowser, clientPath: String,
                 systemEvents: AppSystemEvents? = AppSystemEvents.quiet()) -> LiveBackend {
    LiveBackend(
        store: store,
        accountDependencies: LiveAccountManager.Dependencies(
            environment: ["OPENHUMAN_OAUTH_CLIENT_JSON": clientPath],
            storeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("oh-none-\(UUID().uuidString)"), tokenStore: tokens, transport: google.http,
            makeReceiver: { AnsweringReceiver(browser: browser) }, browser: browser, clock: SystemClock(),
            signInTimeout: .seconds(30), developerClientFile: BuildFlavor.oauthClientFile),
        transports: LiveBackend.Transports(api: google.http, token: google.http),
        userAgent: "OpenHumanMail/test", makeSystemEvents: { systemEvents })
}

extension AppSystemEvents {
    @MainActor
    static func quiet() -> AppSystemEvents {
        AppSystemEvents(application: NotificationCenter(), workspace: NotificationCenter(), monitorsNetwork: false)
    }
}

@MainActor
@Test(.timeLimit(.minutes(2))) func signInStartsTheSessionAndSyncsByReadingOnly() async throws {
    let corpus = FakeCorpus.make(threadCount: 20, now: now)
    let gmail = FakeGmail(accountEmail: corpus.account.email)
    await FakeGmailLaunch.seed(gmail, corpus: corpus)
    let google = FakeGoogle(gmail: gmail)
    let tokens = InMemoryTokenStore()
    let browser = RecordingBrowser()
    let backend = liveBackend(google: google, store: try MailStore.openInMemoryForTesting(), tokens: tokens,
                              browser: browser, clientPath: try SyntheticClient.writeJSON())
    #expect(backend.initialStep() == .signIn(loginHint: "", notice: nil))

    let app = AppModel(live: backend)
    guard case .signIn(let signIn) = app.screen else {
        Issue.record("expected the sign-in screen")
        return
    }
    let runner = Task { await signIn.run() }
    defer { runner.cancel() }
    await eventually("client configured") { signIn.phase == .ready }
    #expect(signIn.clientStatus == .configured(source: .environment))
    signIn.loginHint = corpus.account.email
    signIn.signIn()
    await eventually("mail window") { if case .mail = app.screen { return true }; return false }
    guard case .mail(let environment) = app.screen, let session = app.session else { return }
    defer { Task { await session.stop() } }

    let consent = try #require(browser.urls.first)
    let query = URLComponents(url: consent, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.first { $0.name == "scope" }?.value == GmailScope.modify)
    #expect(!query.contains { $0.name == "include_granted_scopes" })
    #expect(query.first { $0.name == "login_hint" }?.value == corpus.account.email)
    #expect(try tokens.load(account: corpus.account.email)?.grantedScopes == [GmailScope.modify])
    #expect(!environment.isFake && environment.isLiveAccount)

    struct SyncFailed: Error, CustomStringConvertible { var description: String }
    let rows = try await withThrowingTaskGroup(of: ThreadListWindow?.self) { group in
        group.addTask {
            try await firstValue(environment.data.threadWindow(.system(.inbox), account: session.account, limit: 100)) {
                $0.rows.count == 20
            }
        }
        group.addTask {
            while !Task.isCancelled {
                if case .syncFailing(let code, let failures, _) = await session.currentConnectivity() {
                    throw SyncFailed(description: "sync reported \(code) after \(failures) failure(s)")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
        defer { group.cancelAll() }
        return try #require(try await group.next() ?? nil)
    }
    #expect(rows.rows.map(\.subject) == corpus.threads.map(\.detail.subject))
    #expect(backend.initialStep() == .session(try #require(backend.account(session.account))))

    #expect(google.http.requests.filter { !isGET($0) }.map(\.url.path).filter { $0 != "/batch/gmail/v1" } == ["/token"])
    #expect(google.api.requests.allSatisfy(isReadOnTheWire))
}

@MainActor
@Test func aTokenBroaderThanModifyIsNotUsedAtLaunch() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let email = "robin@example.com"
    _ = try store.addAccount(email: email, displayName: nil, scopes: ["https://mail.google.com/"])
    let tokens = InMemoryTokenStore([email: StoredToken(refreshToken: "synthetic-refresh",
                                                        grantedScopes: ["https://mail.google.com/"],
                                                        clientID: SyntheticClient.clientID)])
    let backend = liveBackend(google: FakeGoogle(gmail: FakeGmail(accountEmail: email)), store: store, tokens: tokens,
                              browser: RecordingBrowser(), clientPath: try SyntheticClient.writeJSON())
    guard case .signIn(let hint, let notice) = backend.initialStep() else {
        Issue.record("expected sign-in")
        return
    }
    #expect(hint == email)
    #expect(notice == LiveBackend.broadAccessNotice && notice?.hasSuffix("only for what it uses.") == true)

    try tokens.save(StoredToken(refreshToken: "synthetic-refresh", grantedScopes: [GmailScope.modify],
                                clientID: SyntheticClient.clientID), account: email)
    let id = try #require(try store.accounts().first).id
    #expect(backend.initialStep() == .session(try #require(backend.account(id))))
}

@Test func setupErrorsCarryWordsNotSecrets() {
    #expect(LiveAccountManager.setupError(OAuthError.cancelled).kind == .cancelled)
    #expect(LiveAccountManager.setupError(OAuthError.denied("write sign-in refused: x")).kind == .refused)
    #expect(LiveAccountManager.setupError(OAuthError.insufficientScopes(missing: [GmailScope.readonly])).kind == .refused)
    #expect(LiveAccountManager.setupError(OAuthError.tokenEndpoint(status: 401, error: "invalid_client", description: "d"))
        .message == "Google refused the sign-in. Try again.\nDetails: while exchanging the code, HTTP 401, invalid_client: d")
    #expect(LiveAccountManager.setupError(OAuthError.tokenEndpoint(status: 400, error: "invalid_request", description: nil),
                                          step: .refreshing)
        .message == "Google refused the sign-in. Try again.\nDetails: while refreshing, HTTP 400, invalid_request")
    #expect(LiveAccountManager.setupError(GmailError.unauthorized).message
        == "You signed in, but Gmail didn't answer. Try again in a moment.\nDetails: unauthorized")
    #expect(LiveAccountManager.setupError(TransportError.notConnected).message.contains("Couldn't reach Google"))
}

@Test func setupErrorsPutCodesOnTheDetailsLine() {
    func message(_ error: Error) -> String { LiveAccountManager.setupError(error).message }
    #expect(message(OAuthError.denied("admin_policy_enforced"))
        == "Your organization's Google admin doesn't allow Mail to sign in.")
    #expect(message(OAuthError.denied("interaction_required"))
        == "Google didn't finish the sign-in. Try again.\nDetails: interaction_required")
    #expect(message(OAuthError.denied("Not A Code!")) == "Google didn't finish the sign-in. Try again.\nDetails: unknown")
    #expect(message(OAuthError.insufficientScopes(missing: [GmailScope.readonly]))
        == "Google didn't give Mail permission to read your mail. Sign in again and allow it.")
    #expect(message(OAuthError.insufficientScopes(missing: [GmailScope.modify])).hasPrefix(
        "Google didn't give Mail permission to change your mail. Sign in again and allow it. Nothing was saved.\nDetails: "))
    #expect(message(OAuthError.configurationMissing("client file: file not readable"))
        == LiveAccountManager.clientMissing)
    #expect(!LiveAccountManager.clientMissing.contains("OPENHUMAN") && !LiveAccountManager.clientMissing.contains("xcconfig"))
    #expect(!LiveAccountManager.broaderThanModify.contains("gmail.modify"))
    for error: Error in [OAuthError.denied("admin_policy_enforced"), OAuthError.insufficientScopes(missing: [GmailScope.modify]),
                         OAuthError.tokenEndpoint(status: 400, error: "invalid_grant", description: nil), GmailError.unauthorized] {
        let main = message(error).components(separatedBy: "\nDetails: ")[0]
        #expect(!main.contains("gmail.") && !main.contains("HTTP") && !main.contains("_"), "\(main)")
    }
}

@Test func onlyASafeGoogleDescriptionIsShown() {
    let safe = ["client_secret is missing.", "Malformed auth code.", "Missing required parameter: code_verifier", "Bad Request"]
    for text in safe { #expect(LiveAccountManager.safeDescription(text) == text) }
    let unsafe: [String?] = [
        nil, "", "   ",
        String(repeating: "a ", count: 61),
        "see https://example.invalid/x", "visit www.example.invalid", "code 4/0AbCdEfGhIjKlMnOpQrStUv",
        "token ya29.a0AfH6SMBabcdefghijklmnop", "secret GOCSPX-abcdefghijklmnopqrstuvw",
        "client 1234-synthetic.apps.googleusercontent.com", "caf\u{E9} not ascii", "line\nbreak",
    ]
    for text in unsafe { #expect(LiveAccountManager.safeDescription(text) == nil, "\(text ?? "nil")") }
    #expect(LiveAccountManager.diagnostic(status: 400, code: "Invalid Request!", description: "Bad Request") == "HTTP 400")
    #expect(LiveAccountManager.diagnostic(status: 502, code: nil, description: "Bad Request") == "HTTP 502")
}

@MainActor
@Test func theSignInScreenShowsGooglesInvalidRequestForLoopbackAndPaste() async throws {
    let description = "client_secret is missing."
    do {
        let google = FakeGoogle(gmail: FakeGmail(accountEmail: "robin@example.com"))
        google.http.on("POST", "/token") { _ in
            FakeHTTPTransport.json(400, ["error": "invalid_request", "error_description": description])
        }
        let tokens = InMemoryTokenStore()
        let backend = liveBackend(google: google, store: try MailStore.openInMemoryForTesting(), tokens: tokens,
                                  browser: RecordingBrowser(), clientPath: try SyntheticClient.writeJSON())
        do {
            _ = try await backend.accounts.addAccount(loginHint: nil)
            Issue.record("sign-in should have failed")
        } catch let error as AccountSetupError {
            #expect(error.message == "Google refused the sign-in. Try again.\nDetails: while exchanging the code, "
                + "HTTP 400, invalid_request: client_secret is missing.")
            #expect(!error.message.contains("SYNTHETIC-not-a-secret") && !error.message.contains(SyntheticClient.clientID))
        }
        #expect(try tokens.allAccounts().isEmpty)
    }
}

@Test func aClientWithoutASecretIsReportedBeforeTheBrowserStep() async throws {
    let temp = TemporaryDirectory("oh-nosecret")
    defer { temp.cleanup() }
    let directory = temp.url
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("client.json")
    try Data(#"{"installed":{"client_id":"1234-synthetic.apps.googleusercontent.com"}}"#.utf8).write(to: file)
    let manager = LiveAccountManager(
        store: try MailStore.openInMemoryForTesting(),
        dependencies: LiveAccountManager.Dependencies(
            environment: ["OPENHUMAN_OAUTH_CLIENT_JSON": file.path],
            storeDirectory: directory.appendingPathComponent("none"),
            tokenStore: InMemoryTokenStore(), transport: FakeHTTPTransport(),
            makeReceiver: { AnsweringReceiver(browser: RecordingBrowser()) }, browser: RecordingBrowser(),
            clock: TestClock(), developerClientFile: BuildFlavor.oauthClientFile))
    #expect(manager.currentClientStatus() == .configuredWithoutSecret(source: .environment))
    let withSecret = try SyntheticClient.writeJSON()
    let other = LiveAccountManager(
        store: try MailStore.openInMemoryForTesting(),
        dependencies: LiveAccountManager.Dependencies(
            environment: ["OPENHUMAN_OAUTH_CLIENT_JSON": withSecret],
            storeDirectory: directory.appendingPathComponent("none"),
            tokenStore: InMemoryTokenStore(), transport: FakeHTTPTransport(),
            makeReceiver: { AnsweringReceiver(browser: RecordingBrowser()) }, browser: RecordingBrowser(),
            clock: TestClock(), developerClientFile: BuildFlavor.oauthClientFile))
    #expect(other.currentClientStatus() == .configured(source: .environment))
}

@MainActor
@Test(.timeLimit(.minutes(3))) func theWholeInboxPagesPastTheLiveWindow() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 5_000, now: now)
    let data = MailStoreAdapter(store: store)

    var paged: [ThreadRow] = []
    var cursor: PageCursor?
    repeat {
        let page = try await data.threadPage(.system(.inbox), account: account, after: cursor, limit: 500)
        #expect(page.rows.count <= 500)
        paged += page.rows
        cursor = page.next
    } while cursor != nil
    #expect(paged.count == 5_000)
    #expect(Set(paged.map(\.id)).count == 5_000)
    #expect(paged.first?.subject == "Synthetic thread 0" && paged.last?.subject == "Synthetic thread 4999")
    await #expect(throws: MailPortError.self) {
        _ = try await data.threadPage(.system(.inbox), account: account, after: PageCursor(payload: Data("x".utf8)), limit: 10)
    }

    let list = ThreadListModel(data: data, location: .system(.inbox), account: account)
    list.start()
    defer { list.stop() }
    await eventually("first window") { list.rows.count == 100 }
    #expect(list.totalCount == 5_000 && list.displayCount == 5_000)
    list.visibleRangeDidChange(4_950..<5_000)
    await eventually("every row", timeout: .seconds(60)) { list.rows.count == 5_000 }
    #expect(!list.isPagingUnavailable)
    #expect(list.placeholderCount == 0)
    #expect(list.rows.last?.subject == "Synthetic thread 4999")
    #expect(Set(list.rows.map(\.id)).count == 5_000)

    let counts = try await firstValue(data.counts(account))
    #expect(counts.inboxUnread == (0..<5_000).filter { $0 % 3 == 0 }.count)
    #expect(counts.importantUnread == 0, "the seeded Important split holds nothing here")
    let labels = try await firstValue(data.labels(account))
    let inbox = try #require(labels.first { $0.labelID == GmailLabelID("INBOX") })
    #expect(inbox.displayName == "Inbox" && inbox.totalThreads == 5_000 && counts.byLabel[inbox.id]?.total == 5_000)
    let splits = try await firstValue(data.splits(account))
    #expect(splits.map(\.name) == ["Important", "Calendar"], "the Store's default splits for a new account")
}

@MainActor
@Test(.timeLimit(.minutes(2))) func categoryChipsAndCountsFromALiveSync() async throws {
    let gmail = FakeGmail(accountEmail: "robin@example.com")
    await gmail.deliver(subject: "Personal note", labels: ["INBOX", "CATEGORY_PERSONAL"])
    await gmail.deliver(subject: "Weekly offers", labels: ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"])
    await gmail.deliver(subject: "Build finished", labels: ["INBOX", "UNREAD", "IMPORTANT", "CATEGORY_UPDATES"])
    let running = try FakeGmailLaunch.makeSession(store: try MailStore.openInMemoryForTesting(), gmail: gmail)
    let environment = running.session.environment
    await running.session.start()
    defer { Task { await running.session.stop() } }

    let list = ThreadListModel(data: environment.data, location: .system(.inbox), account: running.session.account)
    list.start()
    defer { list.stop() }
    await eventually("rows and labels") { list.rows.count == 3 && list.labels.count >= 5 }
    func chips(_ subject: String) throws -> [ThreadRowChip] {
        list.chips(for: try #require(list.rows.first { $0.subject == subject }))
    }
    #expect(try chips("Weekly offers").map(\.title) == ["Promotions"])
    #expect(try chips("Build finished").map(\.title) == ["Important", "Updates"], "importance before the category")
    #expect(try chips("Build finished").map(\.kind) == [.important, .category])
    #expect(try chips("Personal note").isEmpty, "Primary is Gmail's default tab, not a chip")

    let counts = try await firstValue(environment.data.counts(running.session.account)) { $0.inboxUnread == 2 }
    #expect(counts.importantUnread == 1)
    #expect(running.wire.requests.allSatisfy(isReadOnTheWire))
}

@MainActor
@Test(.timeLimit(.minutes(2))) func attachmentsAndInlineImagesThroughGETsOnly() async throws {
    let pdf = Data("%PDF-1.4 synthetic quarterly report".utf8)
    let gmail = FakeGmail(accountEmail: "robin@example.com")
    await gmail.deliver(
        subject: "Quarterly report", body: "Chart and report attached.",
        html: "<p>Chart:</p><p><img src=\"cid:chart@fake\" alt=\"chart\"></p>",
        attachments: [FakeGmailAttachment(filename: "report.pdf", mimeType: "application/pdf", data: pdf),
                      FakeGmailAttachment(filename: "chart.png", mimeType: "image/png", data: FakeGmailAttachment.tinyPNG,
                                          contentID: "chart@fake")])
    let (store, directory) = try onDiskStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let running = try FakeGmailLaunch.makeSession(store: store, gmail: gmail)
    let environment = running.session.environment
    await running.session.start()
    defer { Task { await running.session.stop() } }

    let window = try await firstValue(environment.data.threadWindow(.system(.inbox), account: running.session.account,
                                                                    limit: 10)) { $0.rows.count == 1 }
    let reader = ReaderModel(thread: window.rows[0].id, data: environment.data, renderQueue: environment.renderQueue)
    reader.start()
    defer { reader.stop() }
    await eventually("rendered body") {
        if case .rendered(.html) = reader.messages.first?.body { return true }
        return false
    }
    let message = try #require(reader.messages.first)
    guard case .rendered(.html(let rendered)) = message.body else { return }
    #expect(rendered.html.contains("ohcid:chart@fake"), "the inline image is served by the reader's cid handler")
    let file = try #require(message.summary.attachments.first { !$0.isInline })
    let inline = try #require(message.summary.attachments.first { $0.isInline })
    #expect(file.filename == "report.pdf" && inline.contentID == "chart@fake")

    let opened = try await reader.attachmentFile(file, of: message.id)
    #expect(try Data(contentsOf: opened) == pdf)
    #expect(opened.path.hasPrefix(directory.appendingPathComponent("Attachments").path + "/"))
    let mode = try #require(try FileManager.default.attributesOfItem(atPath: opened.path)[.posixPermissions] as? Int)
    #expect(mode == 0o600)
    #expect(AttachmentFiles.quarantine(of: opened) != nil)

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oh-save-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let saved = try await reader.saveAttachment(file, of: message.id, to: folder)
    #expect(try Data(contentsOf: saved) == pdf)
    #expect(AttachmentFiles.quarantine(of: saved) != nil)

    let png = try Data(contentsOf: try await environment.data.attachmentData(message.id, attachment: inline))
    #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

    func attachmentRequests() -> Int {
        running.wire.requests.filter { $0.url.path(percentEncoded: false).contains("/attachments/") }.count
    }
    let requests = attachmentRequests()
    #expect(try await reader.attachmentFile(file, of: message.id) == opened)
    #expect(attachmentRequests() == requests)
    #expect(running.wire.requests.contains { $0.url.path(percentEncoded: false).contains("/attachments/") })
    #expect(running.wire.requests.allSatisfy(isReadOnTheWire))
}

@MainActor
@Test(.timeLimit(.minutes(2))) func readerChoicesPersistAcrossARelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-relaunch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    func open() throws -> MailStore {
        try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .test,
                                        appVersion: "0.0.0-test"))
    }
    let corpus = FakeCorpus.make(threadCount: 8, now: now)
    let first = try open()
    let account = try FixtureStoreSeeder.seed(first, corpus: corpus)

    func reader(over store: MailStore) async throws -> (ReaderModel, MessageKey) {
        let environment = CompositionRoot.environment(store: store)
        let window = try await firstValue(environment.data.threadWindow(.system(.inbox), account: account, limit: 20)) {
            !$0.rows.isEmpty
        }
        let row = try #require(window.rows.first { !$0.participants.allSatisfy(\.isMe) })
        let model = ReaderModel(thread: row.id, data: environment.data, renderQueue: environment.renderQueue)
        model.start()
        await eventually("conversation") { model.state == .loaded && model.messages.contains { $0.summary.from != nil } }
        let key = try #require(model.messages.last { $0.summary.from?.email != FakeCorpus.me.email }?.id)
        return (model, key)
    }

    let (before, key) = try await reader(over: first)
    let entry = try #require(before.alwaysEntry(for: key))
    #expect(before.remembersChoices, "the live composition has a settings port")
    await before.alwaysLoadImages(key)
    await before.setColorOverride(.originalColors, for: key)
    #expect(before.allowedSenders.contains(entry))
    before.stop()
    try first.close()

    let second = try open()
    defer { try? second.close() }
    let (after, sameKey) = try await reader(over: second)
    #expect(sameKey == key)
    await eventually("settings read back") { after.allowedSenders.contains(entry) && !after.colorOverrides.isEmpty }
    #expect(after.imageDecision(key).0 == .load)
    #expect(after.renderContext(key).colorOverride == .originalColors)
    let stored = try await MailStoreSettings(store: second).get(AppSettings.remoteImageSenders(account))
    #expect(stored.contains(entry))
    after.stop()
}

@MainActor
@Test(.timeLimit(.minutes(2))) func markDoneRemovesTheRowAtOnceAndAFailureBringsItBack() async throws {
    let store = try MailStore.openInMemoryForTesting()
    _ = try FixtureStoreSeeder.seed(store, corpus: FakeCorpus.make(threadCount: 12, now: now))
    let commands = GatedCommands()
    let environment = AppEnvironment(data: MailStoreAdapter(store: store), commands: commands,
                                     settings: MailStoreSettings(store: store), isFake: true)
    let window = MailWindowModel(environment: environment)
    window.start()
    await eventually("rows") { (window.list?.rows.count ?? 0) >= 10 }
    let list = try #require(window.list)
    list.moveCursor(by: 2)
    let target = try #require(list.cursor)
    let below = list.rows[try #require(list.index(of: target)) + 1].id
    let count = list.rows.count

    #expect(window.perform(.markDone))
    #expect(list.index(of: target) == nil)
    #expect(list.rows.count == count - 1)
    #expect(list.cursor == below)

    await commands.waitForApply()
    commands.fail()
    await eventually("row back after the failure") { list.index(of: target) != nil }
    #expect(list.rows.count == count)
    #expect(commands.applied == [.markDone([target])])
}

@MainActor
@Test func importanceRulesThroughTheStorePort() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seed(store, corpus: FakeCorpus.make(threadCount: 10, now: now))
    let data = MailStoreAdapter(store: store)
    let window = try await firstValue(data.threadWindow(.system(.inbox), account: account, limit: 20)) { !$0.rows.isEmpty }
    let row = try #require(window.rows.first { !$0.isImportant && !$0.participants.allSatisfy(\.isMe) })
    let sender = try #require(row.participants.first { !$0.isMe }?.email.lowercased())

    let port = MailStoreImportance(store: store)
    let before = try await port.explain(row.id)
    #expect(!before.isImportant && !before.reason.isEmpty)
    #expect(try store.importanceRules(account: account).isEmpty)

    let token = try await port.apply(ImportanceChange(kind: .alwaysSender, account: account, value: sender, thread: row.id))
    let after = try await port.explain(row.id)
    #expect(after.isImportant && after.ruleID != nil)
    let rules = try await firstValue(port.rules(account)) { !$0.isEmpty }
    #expect(rules.map(\.kind) == [.alwaysSender] && rules.first?.value == sender)
    let counts = try await firstValue(data.counts(account))
    #expect((counts.importantUnread ?? 0) == (try store.importanceCounts(account: account).importantUnread))
    _ = try await port.undo(token)
    #expect(try store.importanceRules(account: account).isEmpty)
    #expect(try await !port.explain(row.id).isImportant)
}

final class GatedCommands: MailCommanding, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [MailCommand] = []
    private var waiting: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    var applied: [MailCommand] { lock.withLock { commands } }

    func waitForApply() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if didStart { return true }
                started = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func fail() {
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { waiting = nil }
            return waiting
        }
        gate?.resume()
    }

    func apply(_ command: MailCommand) async throws -> UndoToken {
        await withCheckedContinuation { continuation in
            let starter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                commands.append(command)
                waiting = continuation
                didStart = true
                defer { started = nil }
                return started
            }
            starter?.resume()
        }
        throw MailPortError.unavailable("offline")
    }

    func undo(_ token: UndoToken) async throws -> UndoToken? { throw MailPortError.unsupported("undo") }
    func createDraft(_ input: DraftInput) async throws -> (key: DraftKey, version: Int) { throw MailPortError.unsupported("") }
    func updateDraft(_ key: DraftKey, _ fields: DraftFields, expectedVersion: Int?) async throws -> Int {
        throw MailPortError.unsupported("")
    }
    func flushDraft(_ key: DraftKey) async throws { throw MailPortError.unsupported("") }
    func discardDraft(_ key: DraftKey) async throws { throw MailPortError.unsupported("") }
    func setReviewState(_ key: DraftKey, _ state: DraftReview) async throws { throw MailPortError.unsupported("") }
    func resolveDraftConflict(_ key: DraftKey, _ resolution: DraftConflictResolution) async throws {
        throw MailPortError.unsupported("")
    }
    func send(_ key: DraftKey, undoWindow: Duration) async throws -> SendToken { throw MailPortError.unsupported("") }
    func cancelSend(_ token: SendToken) async throws -> Bool { throw MailPortError.unsupported("") }
    func sendNow(_ token: SendToken) async throws -> Bool { throw MailPortError.unsupported("") }
    func scheduleSend(_ key: DraftKey, at: Date) async throws { throw MailPortError.unsupported("") }
    func cancelScheduledSend(_ key: DraftKey) async throws { throw MailPortError.unsupported("") }
    func fetchDraftNow(_ account: AccountID, gmailDraftID: GmailDraftID) async throws -> DraftKey? {
        throw MailPortError.unsupported("")
    }
    func fetchThreadNow(_ account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadKey? {
        throw MailPortError.unsupported("")
    }
    func createLabel(_ account: AccountID, name: String, applyTo: [ThreadKey]) async throws -> UndoToken {
        throw MailPortError.unsupported("")
    }
    func upsertSnippet(_ snippet: SnippetInfo) async throws -> SnippetInfo { throw MailPortError.unsupported("") }
    func deleteSnippet(_ id: SnippetInfo.ID) async throws { throw MailPortError.unsupported("") }
    func recordSnippetUse(_ id: SnippetInfo.ID) async throws { throw MailPortError.unsupported("") }
    func unsubscribe(_ key: MessageKey) async throws { throw MailPortError.unsupported("") }
    func upsertSplit(_ split: SplitDefinition) async throws -> SplitKey { throw MailPortError.unsupported("") }
    func deleteSplit(_ account: AccountID, _ key: SplitKey) async throws { throw MailPortError.unsupported("") }
    func reorderSplits(_ account: AccountID, _ order: [SplitKey]) async throws { throw MailPortError.unsupported("") }
    func dismissFailedOperation(_ id: FailedOperationInfo.ID) async throws { throw MailPortError.unsupported("") }
}

@MainActor
@Test func anAccountWhoseSignInIsMissingAsksToSignInAgain() throws {
    let store = try MailStore.openInMemoryForTesting()
    _ = try store.addAccount(email: "robin@example.com", displayName: nil, scopes: [GmailScope.modify])
    let backend = liveBackend(google: FakeGoogle(gmail: FakeGmail(accountEmail: "robin@example.com")), store: store,
                              tokens: InMemoryTokenStore(), browser: RecordingBrowser(),
                              clientPath: try SyntheticClient.writeJSON())
    #expect(backend.initialStep() == .signIn(loginHint: "robin@example.com", notice: LiveBackend.signInAgainNotice))
}
