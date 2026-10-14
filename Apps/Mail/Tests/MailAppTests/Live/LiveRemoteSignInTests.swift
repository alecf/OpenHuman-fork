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

private struct Rig {
    let manager: LiveAccountManager
    let google: FakeGoogle
    let tokens: InMemoryTokenStore
    let browser: RecordingBrowser
    let store: MailStore
    let clock: TestClock
}

private func rig(grantedScope: String = GmailScope.readonly, timeout: Duration = .seconds(600)) throws -> Rig {
    let google = FakeGoogle(gmail: FakeGmail(accountEmail: "robin@example.com"), grantedScope: grantedScope)
    let tokens = InMemoryTokenStore()
    let browser = RecordingBrowser()
    let store = try MailStore.openInMemoryForTesting()
    let clock = TestClock()
    let manager = LiveAccountManager(
        safeMode: .readOnly, store: store,
        dependencies: LiveAccountManager.Dependencies(
            environment: ["OPENHUMAN_OAUTH_CLIENT_JSON": try SyntheticClient.writeJSON()],
            storeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("oh-none-\(UUID().uuidString)"), tokenStore: tokens, transport: google.http,
            makeReceiver: { AnsweringReceiver(browser: browser) }, browser: browser, clock: clock,
            signInTimeout: .seconds(30), remoteSignInTimeout: timeout))
    return Rig(manager: manager, google: google, tokens: tokens, browser: browser, store: store, clock: clock)
}

private func query(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

private func redirectAddress(for challenge: RemoteSignInChallenge, code: String = "synthetic-code",
                             state: String? = nil, port: Int? = nil) -> String {
    var components = URLComponents(string: query(challenge.url, "redirect_uri")!)!
    if let port { components.port = port }
    components.queryItems = [URLQueryItem(name: "code", value: code),
                             URLQueryItem(name: "state", value: state ?? query(challenge.url, "state"))]
    return components.string!
}

private func tokenPosts(_ rig: Rig) -> Int { rig.google.http.requests.filter { $0.url.path == "/token" }.count }

private func setupError(_ rig: Rig, _ pasted: String) async -> AccountSetupError? {
    do { _ = try await rig.manager.completeRemoteSignIn(pasted: pasted) } catch { return error as? AccountSetupError }
    return nil
}

@Test func theChallengeIsReadOnlyAndOpensNothing() async throws {
    let r = try rig()
    let challenge = try await r.manager.beginRemoteSignIn(loginHint: "robin@example.com")
    #expect(query(challenge.url, "scope") == GmailScope.readonly)
    #expect(query(challenge.url, "include_granted_scopes") == nil)
    #expect(query(challenge.url, "login_hint") == "robin@example.com")
    #expect(query(challenge.url, "client_id") == SyntheticClient.clientID)
    #expect(query(challenge.url, "code_challenge_method") == "S256")
    #expect(query(challenge.url, "redirect_uri")?.hasPrefix("http://127.0.0.1:") == true)
    #expect(!challenge.url.absoluteString.contains("SYNTHETIC-not-a-secret"), "the client secret is never in the address")
    #expect(challenge.expiresAt == r.clock.now.addingTimeInterval(600))
    #expect(r.browser.urls.isEmpty)
    #expect(r.google.http.requests.isEmpty)
}

@Test func pastingTheRedirectAddressStoresTheTokenAndTheAccount() async throws {
    let r = try rig()
    let challenge = try await r.manager.beginRemoteSignIn(loginHint: nil)
    let id = try await r.manager.completeRemoteSignIn(pasted: " \(redirectAddress(for: challenge))\n")
    #expect(try r.tokens.load(account: "robin@example.com")?.grantedScopes == [GmailScope.readonly])
    #expect(try r.store.accounts().map(\.id) == [id])
    #expect(tokenPosts(r) == 1)
    #expect(r.browser.urls.isEmpty)
    let again = await setupError(r, redirectAddress(for: challenge))
    #expect(again?.kind == .failed)
    #expect(tokenPosts(r) == 1)
}

@Test func aBareCodeAndOtherWrongPastesAreRefusedWithoutContactingGoogle() async throws {
    let r = try rig()
    let challenge = try await r.manager.beginRemoteSignIn(loginHint: nil)
    let secret = "4/0SyntheticCodeSecret"
    let wrongs = [secret,
                  redirectAddress(for: challenge, code: secret, port: 1234),
                  redirectAddress(for: challenge, code: secret, state: "forged"),
                  "http://127.0.0.1:1/oauth2callback?state=\(query(challenge.url, "state")!)"]
    for wrong in wrongs {
        let error = await setupError(r, wrong)
        #expect(error?.kind == .invalidPaste, "\(error?.message ?? "nil")")
        #expect(error?.message.contains(secret) == false)
        #expect(error?.message.contains("forged") == false)
    }
    #expect(tokenPosts(r) == 0)
    #expect(try r.tokens.allAccounts().isEmpty)
    _ = try await r.manager.completeRemoteSignIn(pasted: redirectAddress(for: challenge))
    #expect(try r.tokens.allAccounts() == ["robin@example.com"])
}

@Test func anExpiredOrUsedCodeIsExplainedAndEndsTheSignIn() async throws {
    let r = try rig()
    r.google.http.on("POST", "/token") { _ in
        FakeHTTPTransport.json(400, ["error": "invalid_grant", "error_description": "Bad Request"])
    }
    let challenge = try await r.manager.beginRemoteSignIn(loginHint: nil)
    let error = await setupError(r, redirectAddress(for: challenge))
    #expect(error?.kind == .failed)
    #expect(error?.message.contains("already used or expired") == true)
    #expect(try r.tokens.allAccounts().isEmpty)
    #expect(try r.store.accounts().isEmpty)
    let next = await setupError(r, redirectAddress(for: challenge))
    #expect(next?.message.contains("no sign-in in progress") == true)
    #expect(tokenPosts(r) == 1)
}

@Test func extraScopesAreRefusedAndNothingIsStored() async throws {
    let r = try rig(grantedScope: "\(GmailScope.readonly) \(GmailScope.modify)")
    let challenge = try await r.manager.beginRemoteSignIn(loginHint: nil)
    let error = await setupError(r, redirectAddress(for: challenge))
    #expect(error?.kind == .refused)
    #expect(try r.tokens.allAccounts().isEmpty)
    #expect(try r.store.accounts().isEmpty)
}

@Test func aPendingSignInExpiresOnTheClockAndCancelForgetsIt() async throws {
    let r = try rig(timeout: .seconds(60))
    let challenge = try await r.manager.beginRemoteSignIn(loginHint: nil)
    r.clock.advance(by: .seconds(61))
    let expired = await setupError(r, redirectAddress(for: challenge))
    #expect(expired?.message.contains("expired") == true)
    #expect(tokenPosts(r) == 0)

    let second = try await r.manager.beginRemoteSignIn(loginHint: nil)
    await r.manager.cancelRemoteSignIn()
    let cancelled = await setupError(r, redirectAddress(for: second))
    #expect(cancelled?.message.contains("no sign-in in progress") == true)
    #expect(tokenPosts(r) == 0)
}

@Test func aNewBeginReplacesThePendingOne() async throws {
    let r = try rig()
    let first = try await r.manager.beginRemoteSignIn(loginHint: nil)
    let second = try await r.manager.beginRemoteSignIn(loginHint: nil)
    let stale = await setupError(r, redirectAddress(for: first, state: query(first.url, "state")))
    #expect(stale?.kind == .invalidPaste, "the first attempt's state no longer matches")
    _ = try await r.manager.completeRemoteSignIn(pasted: redirectAddress(for: second))
}

@MainActor
@Test(.timeLimit(.minutes(2))) func remoteSignInThroughTheScreenStartsTheSession() async throws {
    let corpus = FakeCorpus.make(threadCount: 5, now: Date())
    let gmail = FakeGmail(accountEmail: corpus.account.email)
    await FakeGmailLaunch.seed(gmail, corpus: corpus)
    let google = FakeGoogle(gmail: gmail)
    let tokens = InMemoryTokenStore()
    let browser = RecordingBrowser()
    let backend = LiveBackend(
        safeMode: .readOnly, store: try MailStore.openInMemoryForTesting(),
        accountDependencies: LiveAccountManager.Dependencies(
            environment: ["OPENHUMAN_OAUTH_CLIENT_JSON": try SyntheticClient.writeJSON()],
            storeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("oh-none-\(UUID().uuidString)"), tokenStore: tokens, transport: google.http,
            makeReceiver: { AnsweringReceiver(browser: browser) }, browser: browser, clock: SystemClock(),
            signInTimeout: .seconds(30)),
        transports: LiveBackend.Transports(api: google.http, token: google.http), userAgent: "OpenHumanMail/test")
    let app = AppModel(live: backend)
    guard case .signIn(let signIn) = app.screen else {
        Issue.record("expected the sign-in screen")
        return
    }
    let runner = Task { await signIn.run() }
    defer { runner.cancel() }
    await eventually("client configured") { signIn.phase == .ready }
    signIn.beginRemote()
    await eventually("consent address") { signIn.phase == .remotePaste }
    let url = try #require(signIn.remoteURL)
    let challenge = RemoteSignInChallenge(url: url, expiresAt: Date())
    signIn.pastedAddress = redirectAddress(for: challenge)
    signIn.submitPasted()
    #expect(signIn.pastedAddress.isEmpty)
    await eventually("mail window") { if case .mail = app.screen { return true }; return false }
    guard let session = app.session else { return }
    defer { Task { await session.stop() } }
    #expect(try tokens.load(account: corpus.account.email)?.grantedScopes == [GmailScope.readonly])
    #expect(browser.urls.isEmpty)
}

@Test func googlesInvalidRequestIsShownWithItsSafeDescriptionOnThePastePath() async throws {
    let r = try rig()
    r.google.http.on("POST", "/token") { _ in
        FakeHTTPTransport.json(400, ["error": "invalid_request", "error_description": "Malformed auth code."])
    }
    let challenge = try await r.manager.beginRemoteSignIn(loginHint: nil)
    let error = await setupError(r, redirectAddress(for: challenge, code: "4/0SyntheticCodeSecret"))
    #expect(error?.kind == .failed)
    #expect(error?.message == "Google refused the sign-in. Try again.\nDetails: while exchanging the code, "
        + "HTTP 400, invalid_request: Malformed auth code.")
    #expect(error?.message.contains("SyntheticCodeSecret") == false)
}

@Test func anUnsafeDescriptionIsDroppedAndOnlyTheCodeIsShown() async throws {
    let r = try rig()
    r.google.http.on("POST", "/token") { _ in
        FakeHTTPTransport.json(400, ["error": "invalid_request",
                                     "error_description": "bad code 4/0SyntheticCodeSecretAbcdefghijkl"])
    }
    let challenge = try await r.manager.beginRemoteSignIn(loginHint: nil)
    let error = await setupError(r, redirectAddress(for: challenge))
    #expect(error?.message == "Google refused the sign-in. Try again.\nDetails: while exchanging the code, HTTP 400, "
        + "invalid_request")
}

@Test func aPastedAddressWithEncodedCodeAndTrailingParametersReachesTheEndpointDecodedOnce() async throws {
    let r = try rig()
    let challenge = try await r.manager.beginRemoteSignIn(loginHint: nil)
    let state = query(challenge.url, "state")!
    let redirect = query(challenge.url, "redirect_uri")!
    let text = "'\(redirect)?state=\(state)&code=4%2F0SyntheticAbc&scope=email%20profile#x'\n"
    _ = try await r.manager.completeRemoteSignIn(pasted: text)
    let post = try #require(r.google.http.requests.first { $0.url.path == "/token" })
    let body = String(decoding: post.body ?? Data(), as: UTF8.self)
    #expect(body.contains("code=4%2F0SyntheticAbc&") || body.contains("code=4%2F0SyntheticAbc"))
    #expect(body.contains("client_secret=SYNTHETIC-not-a-secret"))
    #expect(!body.contains("scope="))
}
