import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import Synchronization
import Testing

let testBackstop: Duration = .seconds(120)

@MainActor
func eventually(_ what: String, timeout: Duration? = nil, failure: @MainActor () -> String? = { nil },
                _ condition: @MainActor () -> Bool,
                sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let deadline = clock.now + testBackstop
    while !condition() {
        if let message = failure() {
            Issue.record("while waiting for \(what): \(message)", sourceLocation: sourceLocation)
            return
        }
        if clock.now > deadline {
            Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

func firstValue<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>, where predicate: @Sendable (T) -> Bool = { _ in true }) async throws -> T {
    for try await value in stream where predicate(value) { return value }
    throw CancellationError()
}

enum SyntheticClient {
    static let clientID = "1234-synthetic.apps.googleusercontent.com"

    static func writeJSON() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("client.json")
        try Data("""
            {"installed":{"client_id":"\(clientID)","client_secret":"SYNTHETIC-not-a-secret",
            "auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}}
            """.utf8).write(to: url)
        return url.path
    }
}

final class RecordingBrowser: ExternalBrowser {
    private let opened = Mutex<[URL]>([])
    var urls: [URL] { opened.withLock { $0 } }
    func open(_ url: URL) async throws { opened.withLock { $0.append(url) } }
}

final class AnsweringReceiver: LoopbackRedirectReceiver {
    let redirect = URL(string: "http://127.0.0.1:53682/oauth2callback")!
    let browser: RecordingBrowser

    init(browser: RecordingBrowser) { self.browser = browser }

    func start() async throws -> URL { redirect }

    func waitForCallback(timeout: Duration, successHTML: String) async throws -> URLComponents {
        guard let url = browser.urls.last,
              let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value
        else { throw OAuthError.cancelled }
        var components = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "code", value: "synthetic-code"), URLQueryItem(name: "state", value: state)]
        return components
    }

    func stop() async {}
}

final class FakeGoogle: Sendable {
    let gmail: FakeGmail
    let api: FakeGmailTransport
    let http = FakeHTTPTransport()

    init(gmail: FakeGmail, grantedScope: String = GmailScope.readonly) {
        self.gmail = gmail
        let api = FakeGmailTransport(gmail)
        self.api = api
        http.on("POST", "/token") { _ in
            FakeHTTPTransport.json(200, ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh",
                                         "expires_in": 3600, "scope": grantedScope, "token_type": "Bearer"])
        }
        http.on("GET", "/gmail/v1/") { request in try await api.send(request) }
        http.on("POST", "/batch/gmail/v1") { request in try await api.send(request) }
    }
}
