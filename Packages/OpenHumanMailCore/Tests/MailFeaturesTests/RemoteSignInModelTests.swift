import Foundation
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private final class RemoteFake: AccountManaging {
    private struct State {
        var begins: [String?] = []
        var pasted: [String] = []
        var cancels = 0
        var beginResult: Result<RemoteSignInChallenge, AccountSetupError> = .success(challenge)
        var completeResults: [Result<AccountID, AccountSetupError>] = []
        var gate: CheckedContinuation<Void, Never>?
        var holdComplete = false
    }
    static let challenge = RemoteSignInChallenge(url: URL(string: "https://accounts.example.invalid/auth?state=s1")!,
                                                 expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    private let state = Mutex(State())

    var begins: [String?] { state.withLock { $0.begins } }
    var pasted: [String] { state.withLock { $0.pasted } }
    var cancels: Int { state.withLock { $0.cancels } }
    func script(begin: Result<RemoteSignInChallenge, AccountSetupError>? = nil,
                complete: [Result<AccountID, AccountSetupError>] = []) {
        state.withLock { s in
            if let begin { s.beginResult = begin }
            s.completeResults = complete
        }
    }

    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        AsyncStream { $0.yield(.configured(source: .environment)); $0.finish() }
    }
    func importOAuthClient(json: Data) async throws {}
    func addAccount(loginHint: String?) async throws -> AccountID { AccountID(1) }

    func beginRemoteSignIn(loginHint: String?) async throws -> RemoteSignInChallenge {
        try state.withLock { s in
            s.begins.append(loginHint)
            return try s.beginResult.get()
        }
    }
    func completeRemoteSignIn(pasted: String) async throws -> AccountID {
        try state.withLock { s in
            s.pasted.append(pasted)
            guard !s.completeResults.isEmpty else { throw AccountSetupError(.failed, "unscripted") }
            return try s.completeResults.removeFirst().get()
        }
    }
    func cancelRemoteSignIn() async { state.withLock { $0.cancels += 1 } }
}

@MainActor
private func readyModel(_ fake: RemoteFake, timeout: Duration = .seconds(600)) async -> (SignInModel, Task<Void, Never>) {
    let model = SignInModel(accounts: fake, loginHint: " robin@example.com ", remoteTimeout: timeout)
    let runner = Task { await model.run() }
    await eventually { model.phase == .ready }
    return (model, runner)
}

private let pastedAddress = "http://127.0.0.1:50000/oauth2callback?code=synthetic&state=s1"

@MainActor
@Test func remoteSignInSucceedsLikeTheLoopbackPath() async {
    let fake = RemoteFake()
    fake.script(complete: [.success(AccountID(9))])
    let (model, runner) = await readyModel(fake)
    defer { runner.cancel() }
    var signedIn: AccountID?
    model.onSignedIn = { signedIn = $0 }
    model.beginRemote()
    #expect(model.phase == .remotePreparing)
    await eventually { model.phase == .remotePaste }
    #expect(model.remoteURL == RemoteFake.challenge.url)
    #expect(fake.begins == ["robin@example.com"])
    model.pastedAddress = "  \(pastedAddress)\n"
    model.submitPasted()
    #expect(model.pastedAddress.isEmpty, "the field is cleared the moment it is submitted")
    #expect(model.phase == .remoteCompleting)
    await eventually { model.phase == .signedIn(AccountID(9)) }
    #expect(signedIn == AccountID(9))
    #expect(fake.pasted == ["  \(pastedAddress)\n"])
    #expect(model.remoteURL == nil)
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func aWrongPasteKeepsTheSignInPendingAndTheNextOneCanSucceed() async {
    let fake = RemoteFake()
    let wrong = AccountSetupError(.invalidPaste, "That isn't the full address.")
    fake.script(complete: [.failure(wrong), .success(AccountID(4))])
    let (model, runner) = await readyModel(fake)
    defer { runner.cancel() }
    model.beginRemote()
    await eventually { model.phase == .remotePaste }
    model.pastedAddress = "4/0AbcBareCode"
    model.submitPasted()
    await eventually { model.phase == .remotePaste && model.errorMessage != nil }
    #expect(model.errorMessage == "That isn't the full address.")
    #expect(model.pastedAddress.isEmpty)
    #expect(model.remoteURL != nil)
    #expect(fake.cancels == 0)
    model.pastedAddress = pastedAddress
    model.submitPasted()
    await eventually { model.phase == .signedIn(AccountID(4)) }
}

@MainActor
@Test(arguments: [
    AccountSetupError(.failed, "Google no longer accepts that code (already used or expired). Start again."),
    AccountSetupError(.refused, "Google gave Mail more access than it asks for (such as full Gmail access), so Mail "
        + "stopped and saved nothing. Sign in again."),
])
func aSpentSignInReturnsToTheStartWithTheReasonAndNothingKept(error: AccountSetupError) async {
    let fake = RemoteFake()
    fake.script(complete: [.failure(error)])
    let (model, runner) = await readyModel(fake)
    defer { runner.cancel() }
    model.beginRemote()
    await eventually { model.phase == .remotePaste }
    model.pastedAddress = pastedAddress
    model.submitPasted()
    await eventually { model.phase == .ready }
    #expect(model.errorMessage == error.message)
    #expect(model.remoteURL == nil)
    #expect(model.pastedAddress.isEmpty)
    #expect(model.canSignIn)
}

@MainActor
@Test func cancelForgetsThePendingSignIn() async {
    let fake = RemoteFake()
    let (model, runner) = await readyModel(fake)
    defer { runner.cancel() }
    model.beginRemote()
    await eventually { model.phase == .remotePaste }
    model.pastedAddress = "half a paste"
    model.cancelRemote()
    #expect(model.phase == .ready)
    #expect(model.remoteURL == nil)
    #expect(model.pastedAddress.isEmpty)
    #expect(model.errorMessage == nil)
    await eventually { fake.cancels == 1 }
    model.submitPasted()
    #expect(fake.pasted.isEmpty, "nothing is sent after a cancel")
}

@MainActor
@Test func aPendingSignInExpires() async {
    let fake = RemoteFake()
    let (model, runner) = await readyModel(fake, timeout: .milliseconds(30))
    defer { runner.cancel() }
    model.beginRemote()
    await eventually { model.phase == .remotePaste }
    model.pastedAddress = "typing"
    await eventually { model.phase == .ready }
    #expect(model.errorMessage == "That sign-in link expired. Start again.")
    #expect(model.remoteURL == nil)
    #expect(model.pastedAddress.isEmpty)
    await eventually { fake.cancels == 1 }
}

@MainActor
@Test func beginFailuresAreShownAndStartOnlyWhenReady() async {
    let fake = RemoteFake()
    fake.script(begin: .failure(AccountSetupError(.clientMissing, "No usable Google OAuth client.")))
    let (model, runner) = await readyModel(fake)
    defer { runner.cancel() }
    model.beginRemote()
    await eventually { model.phase == .ready && model.errorMessage != nil }
    #expect(model.errorMessage == "No usable Google OAuth client.")
    #expect(model.remoteURL == nil)

    fake.script(begin: .success(RemoteFake.challenge))
    model.beginRemote()
    await eventually { model.phase == .remotePaste }
    model.beginRemote()
    model.signIn()
    #expect(model.phase == .remotePaste)
    #expect(fake.begins.count == 2)
}

@MainActor
@Test func submittingAnEmptyFieldSendsNothing() async {
    let fake = RemoteFake()
    let (model, runner) = await readyModel(fake)
    defer { runner.cancel() }
    model.beginRemote()
    await eventually { model.phase == .remotePaste }
    model.pastedAddress = "   "
    model.submitPasted()
    #expect(model.phase == .remotePaste)
    #expect(model.errorMessage != nil)
    #expect(fake.pasted.isEmpty)
}

@MainActor
private final class FakePasteboard: TextPasteboard {
    var copied: [String] = []
    func copy(_ text: String) { copied.append(text) }
}

@MainActor
@Test func copyAddressPutsTheExactAddressOnThePasteboardAndConfirms() async {
    let fake = RemoteFake()
    let (model, runner) = await readyModel(fake)
    defer { runner.cancel() }
    let board = FakePasteboard()
    model.pasteboard = board
    model.beginRemote()
    await eventually { model.phase == .remotePaste }
    #expect(!model.remoteAddressCopied)
    model.copyRemoteAddress()
    #expect(board.copied == [RemoteFake.challenge.url.absoluteString])
    #expect(model.remoteAddressCopied)
    model.cancelRemote()
    #expect(!model.remoteAddressCopied)
}
