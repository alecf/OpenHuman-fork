import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private struct StatesFake: MailDataSource {
    let base: FakeMailStore
    let states: [[AccountID: ConnectivityState]]

    init(states: [[AccountID: ConnectivityState]] = [], corpus: FakeCorpus = .make(threadCount: 5, now: fixedNow)) {
        base = FakeMailStore(corpus: corpus)
        self.states = states
    }

    func accounts() -> AsyncThrowingStream<[Account], Error> { base.accounts() }
    func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        base.threadWindow(location, account: account, limit: limit)
    }
    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> { base.threadDetail(key) }
    func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> { base.body(key) }
    func connectivity() -> AsyncStream<[AccountID: ConnectivityState]> {
        let states = self.states
        return AsyncStream { continuation in
            for state in states { continuation.yield(state) }
            continuation.finish()
        }
    }
}

@MainActor
@Test func fakesRunWithoutSync() async {
    let env = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow))
    await env.status.run()
    #expect(env.status.connectivity.isEmpty)
    #expect(!env.status.isVisible)
    #expect(env.status.syncText(now: fixedNow) == nil)
}

@MainActor
@Test func onlyARealAccountSessionIsLive() {
    #expect(!AppEnvironment(data: StatesFake(), isFake: true).isLiveAccount, "off unless the session says so")
    #expect(!AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow)).isLiveAccount)
    #expect(AppEnvironment(data: StatesFake(), isFake: true, isLiveAccount: true).isLiveAccount)
}

@Test func syncTextCoversEveryState() {
    let now = fixedNow
    #expect(StatusModel.syncText(.online(syncing: true, lastSyncAt: nil), now: now) == "Syncing your inbox…")
    #expect(StatusModel.syncText(.online(syncing: true, lastSyncAt: now), now: now) == "Syncing…")
    #expect(StatusModel.syncText(.online(syncing: false, lastSyncAt: nil), now: now) == "Waiting to sync")
    #expect(StatusModel.syncText(.online(syncing: false, lastSyncAt: now.addingTimeInterval(-20)), now: now) == "Synced just now")
    #expect(StatusModel.syncText(.online(syncing: false, lastSyncAt: now.addingTimeInterval(-7_300)), now: now) == "Synced 2 hours ago")
    #expect(StatusModel.syncText(.offline(since: nil), now: now) == "Offline. Retrying.")
    #expect(StatusModel.syncText(.rateLimited(until: nil), now: now).contains("slow down"))
    #expect(StatusModel.syncText(.syncFailing(code: "server_503", failures: 2, lastSyncAt: nil), now: now)
        == "Gmail is having trouble. Retrying.")
    #expect(StatusModel.syncText(.needsReauth, now: now).contains("sign in again"))
}

@Test func syncFailuresAreWordsNotCodes() {
    func line(_ code: String) -> String {
        StatusModel.syncText(.syncFailing(code: code, failures: 3, lastSyncAt: nil), now: fixedNow)
    }
    #expect(line("owned_elsewhere") == "Another copy of Mail is syncing this account. Quit it to sync here.")
    #expect(line("server_500") == "Gmail is having trouble. Retrying.")
    #expect(line("unauthorized") == "Gmail refused access to this account. Retrying.")
    #expect(line("forbidden:insufficientPermissions") == "Gmail refused access to this account. Retrying.")
    for code in ["bad_request:invalid", "not_found", "decoding", "store", "mapping", "refused_by_guard", "error"] {
        #expect(line(code) == "Couldn't sync. Retrying.", "\(code)")
    }
    #expect(StatusModel.syncFailureText("owned_elsewhere", account: "Work account")
        == "Another copy of Mail is syncing Work account. Quit it to sync here.")
    #expect(StatusModel.syncFailureText("decoding", account: "Work account") == "Couldn't sync Work account. Retrying.")
}

@MainActor
@Test func theFailingCodeIsKeptForTheTooltip() async {
    let account = AccountID(1)
    let env = AppEnvironment(data: StatesFake(states: [[account: .syncFailing(code: "server_503", failures: 2,
                                                                              lastSyncAt: nil)]]))
    #expect(env.status.syncFailureCode == nil)
    await env.status.run()
    #expect(env.status.syncFailureCode == "server_503")
    #expect(env.status.syncText(now: fixedNow) == "Gmail is having trouble. Retrying.")
}

@MainActor
@Test func onlyAMissingWritePortGatesActions() async {
    let env = AppEnvironment(data: StatesFake(), isFake: true)
    let window = MailWindowModel(environment: env)
    window.start()
    await untilObserved { window.list?.rows.count == 5 }
    #expect(window.perform(.markDone))
    #expect(env.notices.toasts.map(\.message) == ["Mark done isn't available here"])
    #expect(!window.perform(ActionID("thread.unknown")), "an id nobody handles passes through")
}

private final class FakeAccounts: AccountManaging {
    private struct State {
        var status: OAuthClientStatus
        var watchers: [AsyncStream<OAuthClientStatus>.Continuation] = []
        var pending: CheckedContinuation<AccountID, Error>?
        var hints: [String?] = []
        var imported: [Data] = []
    }
    private let state: Mutex<State>
    private let note: String?

    init(status: OAuthClientStatus, note: String? = nil) {
        state = Mutex(State(status: status))
        self.note = note
    }

    func oauthClientImportNote() async -> String? { note }

    var hints: [String?] { state.withLock { $0.hints } }
    var imported: [Data] { state.withLock { $0.imported } }
    var isWaiting: Bool { state.withLock { $0.pending != nil } }

    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        let (stream, continuation) = AsyncStream<OAuthClientStatus>.makeStream()
        let current = state.withLock { s in
            s.watchers.append(continuation)
            return s.status
        }
        continuation.yield(current)
        return stream
    }

    func importOAuthClient(json: Data) async throws {
        guard json == Data("{\"installed\":{}}".utf8) else {
            throw AccountSetupError(.clientMissing, "That file isn't a Google Desktop client JSON (import: test).")
        }
        let watchers = state.withLock { s in
            s.imported.append(json)
            s.status = .configured(source: .file)
            return s.watchers
        }
        for watcher in watchers { watcher.yield(.configured(source: .file)) }
    }

    func addAccount(loginHint: String?) async throws -> AccountID {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { s in
                    s.hints.append(loginHint)
                    s.pending = continuation
                }
            }
        } onCancel: {
            self.answer(.failure(AccountSetupError(.cancelled, "Sign-in was cancelled.")))
        }
    }

    func answer(_ result: Result<AccountID, Error>) {
        let pending = state.withLock { s in
            defer { s.pending = nil }
            return s.pending
        }
        pending?.resume(with: result)
    }
}

@MainActor
@Test func signInWithAConfiguredClient() async throws {
    let accounts = FakeAccounts(status: .configured(source: .environment))
    let model = SignInModel(accounts: accounts, loginHint: " robin@example.com ")
    var signedIn: AccountID?
    model.onSignedIn = { signedIn = $0 }
    let runner = Task { await model.run() }
    defer { runner.cancel() }
    await eventually { model.phase == .ready }
    #expect(model.canSignIn)
    model.signIn()
    #expect(model.phase == .signingIn)
    await eventually { accounts.isWaiting }
    #expect(accounts.hints == ["robin@example.com"])
    accounts.answer(.success(AccountID(7)))
    await eventually { model.phase == .signedIn(AccountID(7)) }
    #expect(signedIn == AccountID(7))
}

@MainActor
@Test func missingClientIsImportedThenSignInFailsWithWords() async throws {
    let accounts = FakeAccounts(status: .missing)
    let model = SignInModel(accounts: accounts)
    let runner = Task { await model.run() }
    defer { runner.cancel() }
    await eventually { model.phase == .needsClient }
    #expect(!model.canSignIn)
    model.signIn()
    #expect(model.phase == .needsClient, "no sign-in without a client")
    await model.importClient(json: Data("not json".utf8))
    #expect(model.errorMessage?.contains("isn't a Google Desktop client JSON") == true)
    await model.importClient(json: Data("{\"installed\":{}}".utf8))
    await eventually { model.phase == .ready }
    #expect(model.errorMessage == nil)
    #expect(accounts.imported.count == 1)

    model.signIn()
    await eventually { accounts.isWaiting }
    accounts.answer(.failure(AccountSetupError(.refused, "Google gave Mail more access than it asks for.")))
    await eventually { model.phase == .ready }
    #expect(model.errorMessage == "Google gave Mail more access than it asks for.")
    #expect(accounts.hints == [nil])
}

@MainActor
@Test func cancelStopsWaitingForTheBrowser() async throws {
    let accounts = FakeAccounts(status: .configured(source: .file))
    let model = SignInModel(accounts: accounts)
    let runner = Task { await model.run() }
    defer { runner.cancel() }
    await eventually { model.phase == .ready }
    model.signIn()
    await eventually { accounts.isWaiting }
    model.cancel()
    #expect(model.phase == .ready)
    await eventually { !accounts.isWaiting }
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func aClientWithoutASecretIsFlaggedBeforeTheBrowserStep() async throws {
    let accounts = FakeAccounts(status: .configuredWithoutSecret(source: .file))
    let model = SignInModel(accounts: accounts)
    let runner = Task { await model.run() }
    defer { runner.cancel() }
    await eventually { model.phase == .ready }
    #expect(model.clientWarning == "This client file is missing its secret, so Google will refuse the sign-in. Import "
        + "the full file from Google Cloud Console.")
    #expect(!model.canSignIn)
    #expect(!model.canSignInFromAnotherDevice)
    #expect(model.canImportClient)
    model.signIn()
    #expect(model.phase == .ready)
    await model.importClient(json: Data("{\"installed\":{}}".utf8))
    await eventually { model.canSignIn }
    #expect(model.clientWarning == nil)
    #expect(!model.canImportClient)
    let ok = SignInModel(accounts: FakeAccounts(status: .configured(source: .file)))
    let runner2 = Task { await ok.run() }
    defer { runner2.cancel() }
    await eventually { ok.phase == .ready }
    #expect(ok.clientWarning == nil)
}

@MainActor
@Test func aSecretlessDevelopmentClientFileSaysToUseTheFullFile() async throws {
    let model = SignInModel(accounts: FakeAccounts(status: .configuredWithoutSecret(source: .environment)))
    let runner = Task { await model.run() }
    defer { runner.cancel() }
    await eventually { model.phase == .ready }
    #expect(model.clientWarning == "The client file set for this development build has no secret. Use the full file, or "
        + "quit and open Mail without it.")
    #expect(!model.canImportClient && !model.canSignIn)
}

@MainActor
@Test func anImportKeptOnThisMacOnlyShowsAOneLineNoteAndStillGoesToSignIn() async throws {
    let note = "Couldn't sync this client to iCloud. It's saved on this Mac, so you can sign in."
    let accounts = FakeAccounts(status: .missing, note: note)
    let model = SignInModel(accounts: accounts)
    let runner = Task { await model.run() }
    defer { runner.cancel() }
    await eventually { model.phase == .needsClient }
    await model.importClient(json: Data("{\"installed\":{}}".utf8))
    #expect(model.clientNote == note && model.errorMessage == nil)
    await eventually { model.phase == .ready && model.canSignIn }
    await model.importClient(json: Data("not json".utf8))
    #expect(model.clientNote == nil && model.errorMessage != nil)
}
