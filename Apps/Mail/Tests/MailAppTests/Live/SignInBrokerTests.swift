import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import Synchronization
import Testing
@testable import OpenHumanMail

private final class FakeBrowserPlatform: Sendable {
    static let browsers = [
        InstalledBrowser(id: "com.example.browser.alpha", name: "Alpha Browser", appPath: "/Applications/Alpha Browser.app"),
        InstalledBrowser(id: "com.example.browser.beta", name: "Beta Browser", appPath: "/Applications/Beta Browser.app"),
    ]
    private let opened = Mutex<[(url: URL, browser: String?)]>([])
    var log: [(url: URL, browser: String?)] { opened.withLock { $0 } }

    var platform: SignInBrowserPlatform {
        SignInBrowserPlatform(
            openDefault: { [self] url in opened.withLock { $0.append((url, nil)) } },
            openWith: { [self] url, browser in opened.withLock { $0.append((url, browser.id)) } },
            browsers: { Self.browsers })
    }
}

private final class MemoryOfChoices: SignInBrowserMemory {
    private let stored = Mutex<[String: String]>([:])
    func browser(for account: String?) -> String? { stored.withLock { $0[account ?? ""] } }
    func remember(_ browser: String?, for account: String?) { stored.withLock { $0[account ?? ""] = browser } }
}

private final class ScriptedReceiver: LoopbackRedirectReceiver {
    enum Answer: Sendable { case never, wrongState, matching }
    let redirect = URL(string: "http://127.0.0.1:\(Int.random(in: 49152...65535))/oauth2callback")!
    private let answer: Answer
    private let state = Mutex<String?>(nil)
    private let stops = Mutex(0)
    var stopCount: Int { stops.withLock { $0 } }

    init(_ answer: Answer) { self.answer = answer }

    func start() async throws -> URL { redirect }
    func expectState(_ state: String) async { self.state.withLock { $0 = state } }

    func waitForCallback(timeout: Duration, successHTML: String) async throws -> URLComponents {
        var components = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        switch answer {
        case .never:
            try await Task.sleep(for: .seconds(3600))
            throw OAuthError.timedOut
        case .wrongState:
            components.queryItems = [URLQueryItem(name: "code", value: "synthetic-code"),
                                     URLQueryItem(name: "state", value: "not-the-state")]
        case .matching:
            components.queryItems = [URLQueryItem(name: "code", value: "synthetic-code"),
                                     URLQueryItem(name: "state", value: state.withLock { $0 })]
        }
        return components
    }

    func stop() async { stops.withLock { $0 += 1 } }
}

private let client = OAuthClientConfig(clientID: "5555-synthetic.apps.googleusercontent.com",
                                       clientSecret: "SYNTHETIC-not-a-secret",
                                       authURI: URL(string: "https://accounts.google.com/o/oauth2/auth")!,
                                       tokenURI: URL(string: "https://oauth2.googleapis.com/token")!)

private func tokenEndpoint() -> FakeHTTPTransport {
    let http = FakeHTTPTransport()
    http.on("POST", "/token") { _ in
        FakeHTTPTransport.json(200, ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh",
                                     "expires_in": 3600, "scope": CalendarScopes.requested(for: .readOnly).joined(separator: " "),
                                     "token_type": "Bearer"])
    }
    return http
}

private func consent(_ broker: SignInBroker, _ receiver: ScriptedReceiver, http: FakeHTTPTransport,
                     clock: any OHClock = SystemClock()) -> CalendarConsent {
    CalendarConsent(client: client, mode: .readOnly, transport: http, receiver: broker.wrap(receiver), browser: broker,
                    clock: clock)
}

private func firstPending(_ broker: SignInBroker) async -> PendingSignIn? {
    for await next in broker.pendingSignIns() where next != nil { return next }
    return nil
}

@Test func onlyGooglesConsentPageIsOpenedOrPublished() async throws {
    let fake = FakeBrowserPlatform()
    let broker = SignInBroker(platform: fake.platform, memory: MemoryOfChoices())
    for refused in ["https://accounts.example.com/o/oauth2/auth?state=x", "http://accounts.google.com/o/oauth2/auth",
                    "https://user@accounts.google.com/o/oauth2/auth", "https://accounts.google.com:8443/o/oauth2/auth",
                    "https://accounts.google.com/somewhere-else"] {
        await #expect(throws: (any Error).self) { try await broker.open(URL(string: refused)!) }
    }
    #expect(fake.log.isEmpty, "nothing that isn't Google's consent page is opened")
    #expect(broker.waitingCount == 0, "nor shown, copied or published")

    let receiver = ScriptedReceiver(.matching)
    let token = try await consent(broker, receiver, http: tokenEndpoint()).authorize(account: "robin@example.com",
                                                                                     timeout: .seconds(30))
    #expect(token.clientID == client.clientID)
    let opened = try #require(fake.log.first?.url)
    #expect(GoogleConsentLink.isValid(opened) && GoogleConsentLink.loginHint(opened) == "robin@example.com")
    #expect(GoogleConsentLink.isCalendarConsent(opened))
    var tampered = URLComponents(url: opened, resolvingAgainstBaseURL: false)!
    tampered.queryItems = (tampered.queryItems ?? []) + [URLQueryItem(name: "include_granted_scopes", value: "true")]
    #expect(!GoogleConsentLink.isValid(tampered.url!), "a folded-grant request is never opened")
    #expect(broker.waitingCount == 0 && receiver.stopCount == 1, "finished: the receiver stopped, the panel is gone")
}

@Test func theChoiceIsRememberedPerAccount() async throws {
    let fake = FakeBrowserPlatform()
    let memory = MemoryOfChoices()
    let broker = SignInBroker(platform: fake.platform, memory: memory)
    #expect(await broker.installedBrowsers().map(\.name) == ["Alpha Browser", "Beta Browser"])

    let first = ScriptedReceiver(.never)
    let flow = Task { try await consent(broker, first, http: tokenEndpoint()).authorize(account: "robin@example.com",
                                                                                        timeout: .seconds(30)) }
    let pending = try #require(await firstPending(broker))
    #expect(pending.account == "robin@example.com" && pending.purpose == .calendar && pending.openedIn == nil)
    try await broker.open(pending.id, in: "com.example.browser.beta")
    #expect(fake.log.map(\.browser) == [nil, "com.example.browser.beta"])
    #expect(await broker.rememberedBrowser(for: "robin@example.com") == "com.example.browser.beta")
    await #expect(throws: SignInBrowserError.self) { try await broker.open(pending.id, in: "com.example.not-installed") }
    await broker.cancel(pending.id)
    _ = await flow.result

    let again = ScriptedReceiver(.matching)
    _ = try await consent(broker, again, http: tokenEndpoint()).authorize(account: "robin@example.com", timeout: .seconds(30))
    #expect(fake.log.last?.browser == "com.example.browser.beta")
    let other = ScriptedReceiver(.matching)
    _ = try await consent(broker, other, http: tokenEndpoint()).authorize(account: "sam@example.org", timeout: .seconds(30))
    #expect(fake.log.last?.browser == nil)
    #expect(memory.browser(for: "sam@example.org") == nil)
}

@Test func cancelStopsTheReceiverAndStoresNothing() async throws {
    let fake = FakeBrowserPlatform()
    let broker = SignInBroker(platform: fake.platform, memory: MemoryOfChoices())
    let receiver = ScriptedReceiver(.never)
    let http = tokenEndpoint()
    let flow = Task { try await consent(broker, receiver, http: http).authorize(account: "robin@example.com",
                                                                                timeout: .seconds(30)) }
    let pending = try #require(await firstPending(broker))
    await broker.cancel(pending.id)
    let outcome = await flow.result
    #expect(throws: OAuthError.cancelled) { try outcome.get() }
    #expect(receiver.stopCount == 1, "the loopback receiver is closed")
    #expect(http.requests.isEmpty, "no code was exchanged")
    #expect(broker.waitingCount == 0)
}

@Test func aTimeoutClosesTheReceiverAndThePanel() async throws {
    let broker = SignInBroker(platform: FakeBrowserPlatform().platform, memory: MemoryOfChoices())
    let receiver = ScriptedReceiver(.never)
    let http = tokenEndpoint()
    await #expect(throws: OAuthError.timedOut) {
        _ = try await consent(broker, receiver, http: http).authorize(account: "robin@example.com",
                                                                      timeout: .milliseconds(200))
    }
    #expect(receiver.stopCount == 1 && broker.waitingCount == 0 && http.requests.isEmpty)
}

@Test func aCallbackWithAnotherStateIsRefused() async throws {
    let broker = SignInBroker(platform: FakeBrowserPlatform().platform, memory: MemoryOfChoices())
    let receiver = ScriptedReceiver(.wrongState)
    let http = tokenEndpoint()
    await #expect(throws: OAuthError.stateMismatch) {
        _ = try await consent(broker, receiver, http: http).authorize(account: "robin@example.com", timeout: .seconds(30))
    }
    #expect(http.requests.isEmpty, "the code is never exchanged")
    #expect(receiver.stopCount == 1 && broker.waitingCount == 0)
}
