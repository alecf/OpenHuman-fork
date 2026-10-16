import Foundation
import MailFeatures
import MailModel
import MailUI
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import SwiftUI
import Synchronization
import Testing
@testable import OpenHumanMailLive

private final class Suspension: @unchecked Sendable {
    private let release = DispatchSemaphore(value: 0)
    private let arrivals: AsyncStream<Void>
    private let arrived: AsyncStream<Void>.Continuation

    init() { (arrivals, arrived) = AsyncStream<Void>.makeStream() }

    func hold() {
        arrived.yield()
        release.wait()
    }

    func entered() async {
        var iterator = arrivals.makeAsyncIterator()
        _ = await iterator.next()
    }

    func resume() { release.signal() }
}

private final class RecordingTokens: TokenStore {
    struct State {
        var tokens: [String: StoredToken] = [:]
        var refusal: Int32?
        var suspension: Suspension?
        var loads = 0
        var loadsOnMain = 0
        var deletes = 0
    }
    let state = Mutex(State())
    let access: FakeAccess?

    init(_ tokens: [String: StoredToken] = [:], access: FakeAccess? = nil) {
        self.access = access
        state.withLock { $0.tokens = tokens }
    }

    var loads: Int { state.withLock { $0.loads } }
    var loadsOnMain: Int { state.withLock { $0.loadsOnMain } }
    var deletes: Int { state.withLock { $0.deletes } }

    func refuse(_ status: Int32?) { state.withLock { $0.refusal = status } }

    func suspendNextLoad() -> Suspension {
        let suspension = Suspension()
        state.withLock { $0.suspension = suspension }
        return suspension
    }

    func load(account email: String) throws -> StoredToken? {
        let onMain = Thread.isMainThread
        let suspension = state.withLock { s -> Suspension? in
            s.loads += 1
            if onMain { s.loadsOnMain += 1 }
            defer { s.suspension = nil }
            return s.suspension
        }
        suspension?.hold()
        let (refusal, token) = state.withLock { ($0.refusal, $0.tokens[email.lowercased()]) }
        if let refusal {
            access?.noteRefusal()
            throw TokenStoreError.keychain(refusal)
        }
        return token
    }

    func save(_ token: StoredToken, account email: String) throws {
        state.withLock { $0.tokens[email.lowercased()] = token }
    }

    func delete(account email: String) throws {
        state.withLock { $0.deletes += 1 }
    }

    func allAccounts() throws -> [String] { state.withLock { $0.tokens.keys.sorted() } }
}

private final class RecordingClients: OAuthClientStore {
    static let client = OAuthClientConfig.google(clientID: "123456789012-launch.apps.example", clientSecret: "SYNTHETIC-SECRET")
    private let counts = Mutex((loads: 0, onMain: 0, refusal: Int32?.none))
    let access: FakeAccess?

    init(access: FakeAccess? = nil) { self.access = access }

    var loads: Int { counts.withLock { $0.loads } }
    var loadsOnMain: Int { counts.withLock { $0.onMain } }

    func refuse(_ status: Int32?) { counts.withLock { $0.refusal = status } }

    func loadAll() throws -> [StoredOAuthClient] {
        let onMain = Thread.isMainThread
        let refusal = counts.withLock { counts -> Int32? in
            counts.loads += 1
            if onMain { counts.onMain += 1 }
            return counts.refusal
        }
        if let refusal {
            access?.noteRefusal()
            throw OAuthClientStoreError.keychain(refusal)
        }
        return [StoredOAuthClient(config: Self.client, isDefault: true, sync: .notSyncing)]
    }

    func save(_ client: OAuthClientConfig, isDefault: Bool, synchronizable: Bool) throws -> OAuthClientSyncState {
        .notSyncing
    }

    func delete(key: String) throws {}
}

private final class FakeAccess: CredentialAccess {
    private struct State {
        var presence: StoredItemPresence
        var refused = false
        var forgets = 0
        var checks = 0
        var checksOnMain = 0
    }
    private let state: Mutex<State>

    init(_ presence: StoredItemPresence = .absent) { state = Mutex(State(presence: presence)) }

    var forgets: Int { state.withLock { $0.forgets } }
    var checks: Int { state.withLock { $0.checks } }
    var checksOnMain: Int { state.withLock { $0.checksOnMain } }

    func noteRefusal() { state.withLock { $0.refused = true } }

    func storedItemPresence() -> StoredItemPresence {
        let onMain = Thread.isMainThread
        return state.withLock { s in
            s.checks += 1
            if onMain { s.checksOnMain += 1 }
            return s.presence
        }
    }

    var hasRefusals: Bool { state.withLock { $0.refused } }

    func forgetRefusals() { state.withLock { $0.forgets += 1; $0.refused = false } }
}

private struct NoReceiver: LoopbackRedirectReceiver {
    func start() async throws -> URL { throw TransportError.cannotConnect }
    func waitForCallback(timeout: Duration, successHTML: String) async throws -> URLComponents {
        throw TransportError.cannotConnect
    }
    func stop() async {}
}

private struct NoBrowser: ExternalBrowser {
    func open(_ url: URL) async throws {}
}

private struct NoNetwork: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw TransportError.notConnected }
}

@MainActor
private struct Harness {
    static let email = "robin@example.com"
    let store: MailStore
    let tokens: RecordingTokens
    let clients: RecordingClients
    let access: FakeAccess?
    let calendarTokens: RecordingTokens?
    let directory = TemporaryDirectory("oh-launch")

    init(scopes: [String] = [GmailScope.modify], token: StoredToken? = nil, access: FakeAccess? = nil,
         calendarTokens: RecordingTokens? = nil, store: MailStore? = nil) throws {
        let store = try store ?? MailStore.openInMemoryForTesting()
        if try store.accounts().isEmpty { _ = try store.addAccount(email: Self.email, displayName: nil, scopes: scopes) }
        self.store = store
        tokens = RecordingTokens(token.map { [Self.email: $0] } ?? [:], access: access)
        clients = RecordingClients(access: access)
        self.access = access
        self.calendarTokens = calendarTokens
    }

    func backend() -> LiveBackend {
        LiveBackend(
            store: store,
            accountDependencies: LiveAccountManager.Dependencies(
                environment: [:], storeDirectory: directory.url, clientStore: clients, tokenStore: tokens,
                transport: NoNetwork(), makeReceiver: { NoReceiver() }, browser: NoBrowser(), clock: SystemClock(),
                calendarTokenStore: calendarTokens, credentialAccess: access),
            transports: LiveBackend.Transports(api: NoNetwork(), token: NoNetwork()), userAgent: "OpenHumanMail/test",
            makeSystemEvents: { nil })
    }

    static func modifyToken() -> StoredToken {
        StoredToken(refreshToken: "synthetic-refresh", grantedScopes: [GmailScope.modify],
                    clientID: RecordingClients.client.clientID)
    }

    static func readOnlyToken() -> StoredToken {
        StoredToken(refreshToken: "synthetic-refresh", grantedScopes: [GmailScope.readonly],
                    clientID: RecordingClients.client.clientID)
    }
}

@MainActor
private func notice(_ app: AppModel) -> StartupProblem? {
    if case .notice(let problem) = app.screen { return problem }
    return nil
}

@MainActor
private func signIn(_ app: AppModel) -> SignInModel? {
    if case .signIn(let model) = app.screen { return model }
    return nil
}

@MainActor
private func isLaunching(_ app: AppModel) -> Bool {
    if case .launching = app.screen { return true }
    return false
}

@MainActor
@Suite struct LaunchCredentialsTests {
    @Test(.timeLimit(.minutes(1)))
    func theLaunchingScreenShowsWhileTheKeychainReadWaits() async throws {
        let h = try Harness()
        let waiting = h.tokens.suspendNextLoad()
        let app = AppModel(live: h.backend())
        #expect(isLaunching(app), "the window opens before any Keychain read")
        await waiting.entered()
        #expect(isLaunching(app), "the read is still waiting for its dialog")
        let rendered = ImageRenderer(content: LaunchingView().frame(width: 320, height: 200)).cgImage
        #expect(rendered != nil, "the main thread is free to draw while the read waits")
        waiting.resume()
        await app.launched()
        #expect(signIn(app)?.notice == LiveBackend.signInAgainNotice)
        #expect(h.tokens.loads >= 1 && h.tokens.loadsOnMain == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func noKeychainReadOfTheLaunchOrTheSignInScreenRunsOnTheMainThread() async throws {
        let h = try Harness(token: Harness.readOnlyToken(), access: FakeAccess(.present))
        let app = AppModel(live: h.backend())
        await app.launched()
        try #require(notice(app)?.action).run()
        await app.launched()
        #expect(signIn(app)?.notice == LiveBackend.writeAccessNotice)
        let live = try #require(app.liveAccounts)
        var statuses = live.oauthClientStatus().makeAsyncIterator()
        #expect(await statuses.next() == .configured(source: .file))
        #expect(h.tokens.loads >= 1 && h.tokens.loadsOnMain == 0)
        #expect(h.clients.loads >= 1 && h.clients.loadsOnMain == 0)
        #expect(h.access?.checks == 1 && h.access?.checksOnMain == 0)
    }

    @Test func aRefusedSignInShowsOneScreenWithTryAgainAndSignInAgain() async throws {
        let access = FakeAccess()
        let h = try Harness(token: Harness.readOnlyToken(), access: access)
        h.tokens.refuse(-128)
        let app = AppModel(live: h.backend())
        await app.launched()
        let problem = try #require(notice(app))
        #expect(problem.title == StartupProblem.keychainRefusedTitle)
        #expect(problem.message == StartupProblem.keychainRefusedMessage)
        #expect(problem.action?.title == "Try again" && problem.secondaryAction?.title == "Sign in again")
        #expect(problem.actionHint != nil && problem.secondaryHint != nil)
        let subject = CredentialChainLog.subject(account: Harness.email)
        #expect(CredentialChainLog.shared.events().contains {
            $0.step == .readSignIn && $0.subject == subject && $0.outcome == .keychain(status: -128)
        })
        #expect(access.forgets == 0)
    }

    @Test func tryAgainForgetsTheRefusalAndReadsAgain() async throws {
        let access = FakeAccess()
        let h = try Harness(token: Harness.readOnlyToken(), access: access)
        h.tokens.refuse(-25293)
        let app = AppModel(live: h.backend())
        await app.launched()
        let tryAgain = try #require(notice(app)?.action)
        let loadsBefore = h.tokens.loads
        h.tokens.refuse(nil)
        tryAgain.run()
        #expect(access.forgets == 1 && !access.hasRefusals)
        #expect(isLaunching(app))
        await app.launched()
        #expect(h.tokens.loads > loadsBefore)
        #expect(signIn(app)?.notice == LiveBackend.writeAccessNotice, "the stored sign-in was read this time")
    }

    @Test func signInAgainOpensSignInAndDeletesNothing() async throws {
        let access = FakeAccess()
        let h = try Harness(token: Harness.readOnlyToken(), access: access)
        h.tokens.refuse(-25308)
        let app = AppModel(live: h.backend())
        await app.launched()
        try #require(notice(app)?.secondaryAction).run()
        let model = try #require(signIn(app))
        #expect(model.loginHint == Harness.email && model.notice == nil)
        #expect(h.tokens.deletes == 0 && access.forgets == 0)
        #expect(try h.store.accounts().map(\.email) == [Harness.email])
    }

    @Test func theExplainerComesBeforeTheFirstReadAndOnlyOnce() async throws {
        let access = FakeAccess(.present)
        let h = try Harness(access: access)
        let app = AppModel(live: h.backend())
        await app.launched()
        let explainer = try #require(notice(app))
        #expect(explainer.title == StartupProblem.keychainExplainerTitle)
        #expect(explainer.message == "macOS may ask for your login password a few times. Choose Always Allow so it "
            + "does not ask again.")
        #expect(explainer.action?.title == "Continue" && explainer.secondaryAction == nil)
        #expect(h.tokens.loads == 0 && h.clients.loads == 0, "nothing that could ask is read before Continue")
        explainer.action?.run()
        await app.launched()
        #expect(signIn(app)?.notice == LiveBackend.signInAgainNotice)
        #expect(try h.store.setting(LiveBackend.promptsExplainedSetting, scope: .global))

        let again = try Harness(access: access, store: h.store)
        let relaunched = AppModel(live: again.backend())
        await relaunched.launched()
        #expect(signIn(relaunched) != nil, "shown once per install")
        #expect(access.checks == 1)
    }

    @Test func theExplainerStaysAwayWhenNothingCanAsk() async throws {
        for presence in [StoredItemPresence.absent, .unknown] {
            let h = try Harness(access: FakeAccess(presence))
            let app = AppModel(live: h.backend())
            await app.launched()
            #expect(signIn(app) != nil, "\(presence)")
            #expect(try h.store.setting(LiveBackend.promptsExplainedSetting, scope: .global) == (presence == .absent),
                    "\(presence): a fresh install owns the items it creates, so it never needs the explainer")
        }
        let none = try Harness()
        let app = AppModel(live: none.backend())
        await app.launched()
        #expect(signIn(app) != nil)
    }

    @Test func preparingASessionReadsEveryItemAwayFromTheMainThread() async throws {
        let calendarTokens = RecordingTokens()
        let h = try Harness(token: Harness.modifyToken(), calendarTokens: calendarTokens)
        let live = h.backend()
        let account = try #require(try h.store.accounts().first)
        let prepared = try await live.prepareSession(for: account)
        #expect(prepared.client.clientID == RecordingClients.client.clientID)
        #expect(prepared.calendar != nil && prepared.connections != nil)
        #expect(h.tokens.loads >= 1 && calendarTokens.loads >= 1 && h.clients.loads >= 1)
        #expect(h.tokens.loadsOnMain == 0 && calendarTokens.loadsOnMain == 0 && h.clients.loadsOnMain == 0)
    }

    @Test func aRefusedClientShowsTheSameScreenAndTryAgainReadsTheClientsAgain() async throws {
        let access = FakeAccess()
        let h = try Harness(token: Harness.modifyToken(), access: access)
        h.clients.refuse(-128)
        let app = AppModel(live: h.backend())
        await app.launched()
        let problem = try #require(notice(app))
        #expect(problem.title == StartupProblem.keychainRefusedTitle && app.session == nil)
        let loadsBefore = h.clients.loads
        problem.action?.run()
        await app.launched()
        #expect(access.forgets == 1)
        #expect(h.clients.loads > loadsBefore, "the clients are asked for again")
        #expect(notice(app)?.title == StartupProblem.keychainRefusedTitle && app.session == nil)
        #expect(h.clients.loadsOnMain == 0 && h.tokens.loadsOnMain == 0)
    }

    @Test func tryAgainAlsoForgetsTheClientListThisLaunchRemembered() throws {
        let access = FakeAccess()
        let h = try Harness(token: Harness.readOnlyToken(), access: access)
        let live = h.backend()
        h.clients.refuse(-128)
        #expect(live.accounts.knownClients().isEmpty)
        h.clients.refuse(nil)
        #expect(live.accounts.knownClients().isEmpty, "the same launch keeps its answer")
        live.forgetKeychainRefusals()
        #expect(live.accounts.knownClients().map(\.clientID) == [RecordingClients.client.clientID])
        #expect(access.forgets == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func calendarLookupsNeverBuildOnTheMainThread() async throws {
        let calendarToken = StoredToken(refreshToken: "synthetic-calendar", grantedScopes: CalendarScopes.request.write,
                                        clientID: RecordingClients.client.clientID)
        let calendarTokens = RecordingTokens([Harness.email: calendarToken])
        let h = try Harness(token: Harness.readOnlyToken(), calendarTokens: calendarTokens)
        let live = h.backend()
        let (built, signal) = AsyncStream<Bool>.makeStream()
        let made = Mutex(0)
        let connections = LiveCalendarConnections(own: nil, ownAccount: AccountID(999), accounts: live.accounts) {
            email, client in
            made.withLock { $0 += 1 }
            defer { signal.yield(Thread.isMainThread) }
            return GoogleCalendarSession(account: email, dependencies: GoogleCalendarSession.Dependencies(
                tokenStore: calendarTokens, client: client, tokenTransport: NoNetwork(), apiTransport: NoNetwork(),
                makeReceiver: { NoReceiver() }, browser: NoBrowser(), clock: SystemClock()))
        }
        #expect(connections.windowCalendarProvider() == nil, "a miss answers at once")
        var builds = built.makeAsyncIterator()
        #expect(await builds.next() == false, "and builds away from the main thread")

        let signedIn = live.accounts.signedInAccounts()
        await Task.detached { connections.prepare(signedIn) }.value
        let before = (h.tokens.loads, calendarTokens.loads, made.withLock { $0 })
        #expect(connections.windowCalendarProvider() != nil)
        #expect(connections.windowCalendarProvider() != nil)
        #expect(made.withLock { $0 } == before.2)
        #expect(h.tokens.loads == before.0 && calendarTokens.loads == before.1, "a hit reads nothing")
        #expect(h.tokens.loadsOnMain == 0 && calendarTokens.loadsOnMain == 0)
    }
}
