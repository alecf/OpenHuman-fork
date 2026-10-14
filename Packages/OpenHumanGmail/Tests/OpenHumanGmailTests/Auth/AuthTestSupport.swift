import Foundation
import OpenHumanCore
import Synchronization
@testable import OpenHumanGmail

final class ScriptedTransport: HTTPTransport {
    typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse
    private let handler: Handler
    private let log = Mutex<[HTTPRequest]>([])

    init(_ handler: @escaping Handler = { _ in jsonResponse(200, [:]) }) {
        self.handler = handler
    }

    var requests: [HTTPRequest] { log.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        log.withLock { $0.append(request) }
        return try await handler(request)
    }
}

func jsonResponse(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
    HTTPResponse(status: status, headers: ["content-type": "application/json"],
                 body: try! JSONSerialization.data(withJSONObject: object))
}

func formFields(_ body: Data?) -> [String: String] {
    guard let body, let text = String(data: body, encoding: .utf8) else { return [:] }
    var fields: [String: String] = [:]
    for pair in text.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        fields[kv[0]] = kv.count > 1 ? kv[1] : ""
    }
    return fields
}

func queryValue(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

final class FakeReceiver: LoopbackRedirectReceiver {
    let redirect: URL
    private struct State {
        var pending: URLComponents?
        var waiter: CheckedContinuation<URLComponents, Error>?
        var cancelled = false
        var started = 0
        var stopped = 0
        var expectedStates: [String] = []
    }
    private let state = Mutex(State())

    init(redirect: URL = URL(string: "http://127.0.0.1:53682/oauth2callback")!) {
        self.redirect = redirect
    }

    var startCount: Int { state.withLock { $0.started } }
    var stopCount: Int { state.withLock { $0.stopped } }
    var expectedStates: [String] { state.withLock { $0.expectedStates } }

    func start() async throws -> URL {
        state.withLock { $0.started += 1 }
        return redirect
    }

    func expectState(_ expected: String) async {
        state.withLock { $0.expectedStates.append(expected) }
    }

    func waitForCallback(timeout: Duration, successHTML: String) async throws -> URLComponents {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLComponents, Error>) in
                let immediate: Result<URLComponents, Error>? = state.withLock { s in
                    if let pending = s.pending { s.pending = nil; return .success(pending) }
                    if s.cancelled { return .failure(CancellationError()) }
                    s.waiter = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<URLComponents, Error>? in
                s.cancelled = true
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func deliver(_ components: URLComponents) {
        let waiter = state.withLock { s -> CheckedContinuation<URLComponents, Error>? in
            guard let waiter = s.waiter else { s.pending = components; return nil }
            s.waiter = nil
            return waiter
        }
        waiter?.resume(returning: components)
    }

    func stop() async { state.withLock { $0.stopped += 1 } }
}

final class FakeBrowser: ExternalBrowser {
    private let opened = Mutex<[URL]>([])
    private let onOpen: @Sendable (URL) throws -> Void

    init(onOpen: @escaping @Sendable (URL) throws -> Void = { _ in }) {
        self.onOpen = onOpen
    }

    var openedURLs: [URL] { opened.withLock { $0 } }

    func open(_ url: URL) async throws {
        opened.withLock { $0.append(url) }
        try onOpen(url)
    }
}

enum Synthetic {
    static let clientID = "1234-synthetic.apps.googleusercontent.com"
    static let clientSecret = "SYNTHETIC-SECRET-not-a-real-one"
    static let client = OAuthClientConfig(
        clientID: clientID, clientSecret: clientSecret,
        authURI: URL(string: "https://accounts.example.invalid/o/oauth2/auth")!,
        tokenURI: URL(string: "https://oauth2.example.invalid/token")!)

    static func installedJSON(clientID: String = clientID, secret: String = clientSecret) -> Data {
        Data("""
        {"installed":{"client_id":"\(clientID)","project_id":"synthetic","client_secret":"\(secret)",
        "auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token",
        "auth_provider_x509_cert_url":"https://www.googleapis.com/oauth2/v1/certs","redirect_uris":["http://localhost"]}}
        """.utf8)
    }

    static func token(access: String? = "synthetic-access-0", expiry: Date?, clientID: String = clientID,
                      scopes: [String] = [GmailScope.readonly]) -> StoredToken {
        StoredToken(refreshToken: "synthetic-refresh-0", accessToken: access, accessTokenExpiry: expiry,
                    grantedScopes: scopes, clientID: clientID)
    }

    static func token(refresh: String, access: String? = nil, expiry: Date? = nil, clientID: String = clientID,
                      scopes: [String] = [GmailScope.readonly]) -> StoredToken {
        StoredToken(refreshToken: refresh, accessToken: access, accessTokenExpiry: expiry, grantedScopes: scopes,
                    clientID: clientID)
    }

    static func result(email: String, token: StoredToken) -> OAuthResult {
        OAuthResult(email: email, token: token,
                    profile: GmailProfile(emailAddress: email, messagesTotal: 0, threadsTotal: 0, historyId: "1"))
    }
}

struct TempDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openhuman-auth-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

func posixMode(_ url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_mode & 0o777
}

func eventually(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed = state.withLock { s -> Bool in
                if s.isOpen { return true }
                s.waiters.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

final class EventLog: Sendable {
    private let events = Mutex<[TokenEvent]>([])
    var all: [TokenEvent] { events.withLock { $0 } }
    var sink: @Sendable (TokenEvent) -> Void { { [weak self] event in self?.events.withLock { $0.append(event) } } }
}

func perAccountTokenEndpoint(rejected: Set<String>, scope: String? = GmailScope.readonly) -> ScriptedTransport {
    ScriptedTransport { request in
        let refresh = formFields(request.body)["refresh_token"] ?? ""
        if rejected.contains(refresh) {
            return jsonResponse(400, ["error": "invalid_grant", "error_description": "Token has been expired or revoked."])
        }
        var body: [String: Any] = ["access_token": "access-for-\(refresh)", "expires_in": 3600, "token_type": "Bearer"]
        if let scope { body["scope"] = scope }
        return jsonResponse(200, body)
    }
}
