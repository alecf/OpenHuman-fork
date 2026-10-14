import Foundation
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private final class SimpleSignInFake: AccountManaging {
    private struct Counts { var adds = 0, begins = 0 }
    let status: OAuthClientStatus
    let waits: Bool
    let syncs: Bool
    private let counts = Mutex(Counts())

    init(_ status: OAuthClientStatus, waits: Bool = false, syncs: Bool = false) {
        self.status = status
        self.waits = waits
        self.syncs = syncs
    }

    func signInsSyncThroughICloudKeychain() async -> Bool { syncs }

    var adds: Int { counts.withLock { $0.adds } }
    var begins: Int { counts.withLock { $0.begins } }

    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        let status = status
        return AsyncStream { $0.yield(status); $0.finish() }
    }
    func importOAuthClient(json: Data) async throws {}
    func addAccount(loginHint: String?) async throws -> AccountID {
        counts.withLock { $0.adds += 1 }
        if waits { try await Task.sleep(for: .seconds(3600)) }
        return AccountID(1)
    }
    func beginRemoteSignIn(loginHint: String?) async throws -> RemoteSignInChallenge {
        counts.withLock { $0.begins += 1 }
        return RemoteSignInChallenge(url: URL(string: "https://accounts.example.invalid/auth?state=simple")!,
                                     expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }
    func cancelRemoteSignIn() async {}
}

enum SignInCopyRules {
    static func sentenceCount(_ text: String) -> Int {
        let chars = Array(text)
        return chars.indices.filter { index in
            ".?!".contains(chars[index]) && (index == chars.count - 1 || chars[index + 1] == " ")
        }.count
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

@MainActor
struct SignInSimpleTests {
    private static let statuses: [OAuthClientStatus] = [
        .configured(source: .file), .configured(source: .environment), .missing,
        .configuredWithoutSecret(source: .file), .configuredWithoutSecret(source: .environment),
    ]

    private func model(_ fake: SimpleSignInFake, notice: String? = nil) async -> (SignInModel, Task<Void, Never>) {
        let model = SignInModel(accounts: fake, safeMode: .normal, notice: notice)
        let runner = Task { await model.run() }
        await eventually { model.phase != .checking }
        return (model, runner)
    }

    private func expectOneSentenceOneAction(_ screen: SignInScreen, _ context: String, maxWords: Int = 12) {
        #expect(screen.appName == "OpenHuman Mail", "\(context)")
        #expect(SignInCopyRules.sentenceCount(screen.sentence) == 1, "\(context): \(screen.sentence)")
        #expect(SignInCopyRules.wordCount(screen.sentence) <= maxWords, "\(context): \(screen.sentence)")
        #expect(screen.buttons.count <= 1, "\(context): \(screen.buttons)")
    }

    @Test func everyRestingScreenIsOneSentenceAndOneAction() async {
        let checking = SignInModel(accounts: SimpleSignInFake(.missing), safeMode: .normal)
        expectOneSentenceOneAction(checking.screen, "checking")
        for status in Self.statuses {
            let fake = SimpleSignInFake(status)
            let (model, runner) = await model(fake)
            expectOneSentenceOneAction(model.screen, "\(status)")
            #expect(!model.showsMoreOptions && !model.showsAccessInfo && !model.showsOwnClient, "collapsed: \(status)")
            #expect(fake.adds == 0 && fake.begins == 0, "nothing opens before a press: \(status)")
            runner.cancel()
        }
    }

    @Test func theOneActionFitsTheState() async {
        let expected: [(OAuthClientStatus, SignInScreen.Action?, String?)] = [
            (.configured(source: .file), .signIn, "Sign in with Google"),
            (.configured(source: .environment), .signIn, "Sign in with Google"),
            (.missing, .setUpGoogle, "Set up Google"),
            (.configuredWithoutSecret(source: .file), .importClientFile, "Import client file…"),
            (.configuredWithoutSecret(source: .environment), nil, nil),
        ]
        for (status, action, title) in expected {
            let (model, runner) = await model(SimpleSignInFake(status))
            #expect(model.screen.action == action && model.screen.actionTitle == title, "\(status)")
            runner.cancel()
        }
        let (ready, runner) = await model(SimpleSignInFake(.configured(source: .file)))
        defer { runner.cancel() }
        #expect(ready.screen.sentence == SignInModel.readySentence)
        for marketing in ["keeps up", "Local-first", "open source", "servers"] {
            #expect(!ready.screen.sentence.contains(marketing), "no marketing on the main screen")
        }
    }

    @Test func waitingAndTheOtherDeviceStepsKeepTheRule() async {
        let fake = SimpleSignInFake(.configured(source: .file), waits: true)
        let (model, runner) = await model(fake)
        defer { runner.cancel() }
        model.signIn()
        #expect(model.phase == .signingIn)
        expectOneSentenceOneAction(model.screen, "waiting")
        #expect(model.screen.action == .cancel && model.moreOptions.isEmpty)
        await eventually { fake.adds == 1 }
        model.cancel()
        #expect(model.phase == .ready)
        model.beginRemote()
        await eventually { model.phase == .remotePaste }
        expectOneSentenceOneAction(model.screen, "another device")
        #expect(model.screen.buttons.isEmpty && model.moreOptions.isEmpty)
        model.cancelRemote()
        #expect(model.phase == .ready)
    }

    @Test func aNoticeTakesTheSentencesPlace() async {
        let notice = "To make changes, sign in again and allow Mail to change your mail."
        let (model, runner) = await model(SimpleSignInFake(.configured(source: .file)), notice: notice)
        defer { runner.cancel() }
        #expect(model.screen.sentence == notice && model.screen.action == .signIn)
        expectOneSentenceOneAction(model.screen, "notice", maxWords: 14)
        #expect(!model.moreOptions.contains(.ownClient), "signing in again keeps the current client")
    }

    @Test func moreOptionsIsCollapsedByDefaultAndHoldsTheRest() async {
        let (own, ownRunner) = await model(SimpleSignInFake(.configured(source: .file)))
        #expect(own.moreOptions == [.specificAccount, .anotherDevice, .ownClient, .whatMailAsksFor])
        #expect(!own.showsMoreOptions)
        own.toggleMoreOptions()
        #expect(own.showsMoreOptions)
        own.toggleAccessInfo()
        #expect(own.showsAccessInfo)
        own.toggleMoreOptions()
        #expect(!own.showsMoreOptions)
        ownRunner.cancel()

        let (env, envRunner) = await model(SimpleSignInFake(.configured(source: .environment)))
        #expect(env.moreOptions == [.specificAccount, .anotherDevice, .clientChoice, .whatMailAsksFor])
        envRunner.cancel()

        let (none, noneRunner) = await model(SimpleSignInFake(.missing))
        #expect(none.moreOptions == [.haveClientFile], "no access words before a client exists to sign in with")
        noneRunner.cancel()

        let (noSecret, noSecretRunner) = await model(SimpleSignInFake(.configuredWithoutSecret(source: .file)))
        #expect(noSecret.moreOptions.contains(.clientFileHelp) && noSecret.moreOptions.contains(.whatMailAsksFor))
        #expect(!noSecret.moreOptions.contains(.specificAccount) && !noSecret.moreOptions.contains(.anotherDevice),
                "nothing that could only fail")
        noSecretRunner.cancel()
    }

    @Test func theFlowsBehindMoreOptionsStillWork() async {
        let fake = SimpleSignInFake(.configured(source: .file))
        let (model, runner) = await model(fake)
        defer { runner.cancel() }
        #expect(!model.showsAccountField)
        model.useSpecificAccount()
        #expect(model.showsAccountField)
        model.toggleOwnClient()
        #expect(model.showsOwnClient)
        model.openClientGuide()
        #expect(model.showsClientGuide)
        model.closeClientGuide()
        model.beginRemote()
        await eventually { model.phase == .remotePaste }
        #expect(fake.begins == 1 && model.remoteURL != nil)
        model.cancelRemote()
        model.loginHint = "robin@example.com"
        model.signIn()
        await eventually { model.phase == .signedIn(AccountID(1)) }
        #expect(fake.adds == 1)

        let (none, noneRunner) = await self.model(SimpleSignInFake(.missing))
        defer { noneRunner.cancel() }
        #expect(none.screen.action == .setUpGoogle)
        none.openClientGuide()
        #expect(none.showsClientGuide)
    }

    @Test func theProductNameIsTwoWordsAndTheIdentifiersStay() {
        #expect(SignInModel.appName == "OpenHuman Mail" && OHIdentifiers.productName == "OpenHuman Mail")
        #expect(OHIdentifiers.prefix == "dev.openhuman.mail")
        #expect(OHIdentifiers.keychainService == "dev.openhuman.mail.oauth.v1")
        #expect(OHIdentifiers.appGroup == "group.dev.openhuman.mail")
        #expect(GoogleClientGuide.plainText.hasPrefix("How to get a Google client file for OpenHuman Mail"))
    }
}

@MainActor
@Test func theKeychainSentenceShowsWhereverSigningInIsOfferedAndPromisesSyncOnlyWhenItHappens() async {
    #expect(SignInModel.keychainSyncNote
        == "Your sign-in is kept in your Keychain and syncs through iCloud Keychain if you have it turned on.")
    #expect(SignInModel.keychainLocalNote == "Your sign-in is kept in this Mac's Keychain.")

    let local = SignInModel(accounts: SimpleSignInFake(.configured(source: .file), waits: true), safeMode: .normal)
    await local.run()
    #expect(local.screen.action == .signIn && local.showsKeychainNote)
    #expect(local.keychainNote == SignInModel.keychainLocalNote, "this build keeps sign-ins on this Mac")
    local.signIn()
    #expect(local.phase == .signingIn && local.showsKeychainNote, "still there while the browser finishes")
    local.cancel()

    let synced = SignInModel(accounts: SimpleSignInFake(.configured(source: .file), syncs: true), safeMode: .normal)
    await synced.run()
    #expect(synced.showsKeychainNote && synced.keychainNote == SignInModel.keychainSyncNote)

    let noClient = SignInModel(accounts: SimpleSignInFake(.missing), safeMode: .normal)
    await noClient.run()
    #expect(noClient.screen.action == .setUpGoogle && !noClient.showsKeychainNote, "no sign-in offered yet")
}
