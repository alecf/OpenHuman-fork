import AppKit
import Foundation
import MailActions
import MailFakes
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import OpenHumanSync
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

private func requests(_ wire: FakeGmailTransport, endingWith suffix: String) -> Int {
    wire.requests.filter { $0.url.path(percentEncoded: false).hasSuffix(suffix) }.count
}

@MainActor
private final class Flag {
    var isSet = false
}

@MainActor
@Test(.timeLimit(.minutes(3))) func appKitEventsMoveTheEnginesPoll() async throws {
    let corpus = FakeCorpus.make(threadCount: 8, now: Date())
    let gmail = FakeGmail(accountEmail: corpus.account.email)
    await FakeGmailLaunch.seed(gmail, corpus: corpus)
    let application = NotificationCenter()
    let workspace = NotificationCenter()
    let events = AppSystemEvents(application: application, workspace: workspace, monitorsNetwork: false)
    let running = try FakeGmailLaunch.makeSession(store: try MailStore.openInMemoryForTesting(),
                                                  gmail: gmail, pollInterval: .seconds(3_600), systemEvents: events)
    let session = running.session
    let status = session.environment.status
    let follower = Task { await status.run() }
    defer { follower.cancel() }
    await session.start()
    defer { Task { await session.stop() } }
    await eventually("first sync and backfill", timeout: .seconds(60)) { session.backfillProgress?.stage == .complete }
    await eventually("synced status") { status.syncText(now: Date())?.hasPrefix("Synced") == true }
    let wire = running.wire
    func finishedSync() -> Date {
        guard case let .online(syncing, last)? = status.connectivity[session.account], !syncing else { return .distantPast }
        return last ?? .distantPast
    }

    var history = requests(wire, endingWith: "/history")
    var synced = finishedSync()
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    await eventually("a sync on wake") { requests(wire, endingWith: "/history") > history }
    await eventually("the wake sync to finish") { finishedSync() > synced }

    history = requests(wire, endingWith: "/history")
    synced = finishedSync()
    let labels = requests(wire, endingWith: "/labels")
    application.post(name: NSApplication.didResignActiveNotification, object: nil)
    application.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    await eventually("a sync and a labels refresh on coming back") {
        requests(wire, endingWith: "/history") > history && requests(wire, endingWith: "/labels") > labels
    }
    await eventually("that sync to finish") { finishedSync() > synced }

    events.networkChanged(false)
    await eventually("offline in the status area") { status.syncText(now: Date()) == "Offline. Retrying." }
    history = requests(wire, endingWith: "/history")
    events.networkChanged(true)
    await eventually("a sync when the network returns") { requests(wire, endingWith: "/history") > history }
    await eventually("synced again") { status.syncText(now: Date())?.hasPrefix("Synced") == true }

    #expect(wire.requests.allSatisfy(isReadOnTheWire))
}

@MainActor
@Test(.timeLimit(.minutes(2))) func tokenEventsReachTheEngine() async throws {
    let corpus = FakeCorpus.make(threadCount: 5, now: Date())
    let gmail = FakeGmail(accountEmail: corpus.account.email)
    await FakeGmailLaunch.seed(gmail, corpus: corpus)
    let extra = "https://www.googleapis.com/auth/userinfo.email"
    let google = FakeGoogle(gmail: gmail, grantedScope: "\(GmailScope.modify) \(extra)")
    let email = corpus.account.email
    let store = try MailStore.openInMemoryForTesting()
    _ = try store.addAccount(email: email, displayName: nil, scopes: [GmailScope.modify])
    let token = StoredToken(refreshToken: "synthetic-refresh", grantedScopes: [GmailScope.modify],
                            clientID: SyntheticClient.clientID)
    let tokens = InMemoryTokenStore([email: token])
    let backend = liveBackend(google: google, store: store, tokens: tokens, browser: RecordingBrowser(),
                              clientPath: try SyntheticClient.writeJSON())
    let app = AppModel(live: backend)
    await app.launched()
    guard case .mail = app.screen, let session = app.session else {
        Issue.record("expected the mail window")
        return
    }
    defer { Task { await session.stop() } }

    await eventually("the new grant on the account row") {
        (try? store.accounts())?.first?.grantedScopes.contains(extra) == true
    }
    #expect(try tokens.load(account: email)?.grantedScopes.contains(extra) == true)
    #expect(google.http.requests.contains { $0.url.path == "/token" })
    #expect(google.api.requests.allSatisfy(isReadOnTheWire))
}

@MainActor
@Test(.timeLimit(.minutes(2))) func quittingFlushesAndStopsTheEngine() async throws {
    let corpus = FakeCorpus.make(threadCount: 6, now: Date())
    let gmail = FakeGmail(accountEmail: corpus.account.email)
    await FakeGmailLaunch.seed(gmail, corpus: corpus)
    let store = try MailStore.openInMemoryForTesting()
    let running = try FakeGmailLaunch.makeSession(store: store, gmail: gmail)
    let session = running.session
    await session.start()
    await eventually("synced") { (try? store.syncStatus(account: session.account).lastSuccessAt) != nil }
    #expect(try store.lease(account: session.account)?.kind == "app", "the engine owns the account")

    let app = AppModel(screen: .mail(session.environment), session: session)
    let finished = Flag()
    AppDelegate.shutDownEngine(app) { finished.isSet = true }
    await eventually("quit finished") { finished.isSet }
    #expect(try store.lease(account: session.account) == nil, "the lease is released, so the next launch syncs at once")
    #expect(session.backfillProgress == nil)
    #expect(running.wire.requests.allSatisfy(isReadOnTheWire))
}

@Test func aTokenBroaderThanModifyIsNeverHandedToAClient() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-none-\(UUID().uuidString)")
    let client = try OAuthClientConfig.load(clientFile: try SyntheticClient.writeJSON(), storeDirectory: directory)
    let tokens = InMemoryTokenStore([
        "robin@example.com": StoredToken(refreshToken: "synthetic-1", grantedScopes: [GmailScope.modify],
                                         clientID: SyntheticClient.clientID),
        "sam@example.com": StoredToken(refreshToken: "synthetic-2", grantedScopes: [GmailScope.readonly],
                                       clientID: SyntheticClient.clientID),
        "kim@example.com": StoredToken(refreshToken: "synthetic-3", grantedScopes: ["https://mail.google.com/"],
                                       clientID: SyntheticClient.clientID),
        "lee@example.com": StoredToken(refreshToken: "synthetic-4",
                                       grantedScopes: [GmailScope.modify, "https://www.googleapis.com/auth/gmail.settings.basic"],
                                       clientID: SyntheticClient.clientID),
    ])
    let credentials = AccountCredentials(store: tokens, client: client, transport: FakeHTTPTransport(), clock: SystemClock())
    for broader in ["kim@example.com", "lee@example.com", "nobody@example.com"] {
        #expect(throws: GmailError.reauthRequired, "\(broader)") {
            try LiveBackend.credentials(broader, from: credentials)
        }
    }
    #expect(try LiveBackend.credentials("robin@example.com", from: credentials).grantedScopes == [GmailScope.modify])
    #expect(try LiveBackend.credentials("sam@example.com", from: credentials).grantedScopes == [GmailScope.readonly],
            "a narrower grant is passed on; the client factory then asks to sign in again")
    #expect(LiveBackend.scopeRefusal([GmailScope.readonly, GmailScope.modify, "openid"]) == nil)
    #expect(LiveBackend.scopeRefusal(["https://mail.google.com/", GmailScope.modify]) == "https://mail.google.com/")
}

@MainActor
@Test func anAccountThatCannotSyncDoesNotHideOneThatCan() throws {
    let tokens = InMemoryTokenStore(["robin@example.com": StoredToken(refreshToken: "synthetic-refresh",
                                                                      grantedScopes: [GmailScope.modify],
                                                                      clientID: SyntheticClient.clientID)])
    func backend(_ store: MailStore) throws -> LiveBackend {
        liveBackend(google: FakeGoogle(gmail: FakeGmail(accountEmail: "robin@example.com")), store: store, tokens: tokens,
                    browser: RecordingBrowser(), clientPath: try SyntheticClient.writeJSON(), systemEvents: nil)
    }
    let store = try MailStore.openInMemoryForTesting()
    let stale = try store.addAccount(email: "old@example.com", displayName: nil, scopes: [GmailScope.modify])
    try store.setAccountStatus(stale, .needsReauth)
    let usable = try store.addAccount(email: "robin@example.com", displayName: nil, scopes: [GmailScope.modify])
    let live = try backend(store)
    #expect(live.initialStep() == .session(try #require(live.account(usable))))

    let alone = try MailStore.openInMemoryForTesting()
    _ = try alone.addAccount(email: "old@example.com", displayName: nil, scopes: [GmailScope.modify])
    try alone.setAccountStatus(try #require(try alone.accounts().first).id, .needsReauth)
    #expect(try backend(alone).initialStep()
        == .signIn(loginHint: "old@example.com", notice: "Google signed this account out. Sign in again."))
}

@MainActor
@Test func theEnginesSchedulersComeFromTheFeatureModules() throws {
    let store = try MailStore.openInMemoryForTesting()
    let all = AppEnvironment(data: MailStoreAdapter(store: store), featureFlags: FeatureFlags())
    #expect(SyncSession.schedulers(all.modules) == Set(ScheduleKind.allCases))
    let noSnooze = AppEnvironment(data: MailStoreAdapter(store: store), featureFlags: FeatureFlags([.snooze: false]))
    #expect(SyncSession.schedulers(noSnooze.modules) == [.reminder, .sendLater])
}
