import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanGmail

@Suite struct CalendarParityScopeTests {
    @Test func theScopeListIsOneConstant() {
        #expect(CalendarScopes.all == Set(CalendarScopes.request.write + CalendarScopes.request.read))
    }

    @Test func aGrantBeyondTheRecordedRequestIsRefused() {
        let read = CalendarScopes.request.read, write = CalendarScopes.request.write
        #expect(CalendarScopes.beyondPinned(granted: read, pinned: read) == nil)
        #expect(CalendarScopes.beyondPinned(granted: read + ["openid"], pinned: read) == nil, "identity scopes add nothing")
        #expect(CalendarScopes.beyondPinned(granted: write, pinned: read) == CalendarScope.events)
        #expect(CalendarScopes.beyondPinned(granted: write + [CalendarScope.eventsReadonly], pinned: write) == nil,
                "read next to write adds nothing, as at consent")
        #expect(CalendarScopes.beyondPinned(granted: read + ["https://www.googleapis.com/auth/gmail.readonly"], pinned: read)
                != nil, "never a Gmail scope")
    }
}

@Suite struct GoogleConsentLinkTests {
    private func flowURL(loginHint: String? = "robin@example.com",
                         scopes: [String] = CalendarScopes.request.read) -> URL {
        let flow = OAuthFlow(client: OAuthClientConfig(clientID: "6666-synthetic.apps.googleusercontent.com",
                                                       authURI: OAuthClientConfig.defaultAuthURI,
                                                       tokenURI: OAuthClientConfig.defaultTokenURI),
                             scopes: scopes, transport: FakeTokenTransport(), receiver: NeverReceiver(),
                             browser: NoBrowser(), clock: SystemClock())
        return flow.authorizationURL(redirectURI: URL(string: "http://127.0.0.1:53682/oauth2callback")!,
                                     challenge: "synthetic-challenge", state: "synthetic-state", loginHint: loginHint)
    }

    @Test func theFlowsOwnAddressPassesAndNothingElse() throws {
        let url = flowURL()
        #expect(GoogleConsentLink.isValid(url))
        #expect(GoogleConsentLink.loginHint(url) == "robin@example.com")
        #expect(GoogleConsentLink.redirectURI(url)?.absoluteString == "http://127.0.0.1:53682/oauth2callback")
        #expect(GoogleConsentLink.isCalendarConsent(url))
        #expect(!GoogleConsentLink.isCalendarConsent(flowURL(scopes: [GmailScope.modify])))
        #expect(GoogleConsentLink.loginHint(flowURL(loginHint: nil)) == nil)

        func altered(_ change: (inout URLComponents) -> Void) -> URL {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            change(&parts)
            return parts.url!
        }
        #expect(!GoogleConsentLink.isValid(altered { $0.host = "accounts.google.com.example.net" }))
        #expect(!GoogleConsentLink.isValid(altered { $0.scheme = "http" }))
        #expect(!GoogleConsentLink.isValid(altered { $0.user = "someone" }))
        #expect(!GoogleConsentLink.isValid(altered { $0.port = 8443 }))
        #expect(!GoogleConsentLink.isValid(altered { $0.path = "/elsewhere" }))
        #expect(!GoogleConsentLink.isValid(altered { $0.queryItems = ($0.queryItems ?? []).filter { $0.name != "state" } }))
        #expect(!GoogleConsentLink.isValid(altered {
            $0.queryItems = ($0.queryItems ?? []).map { $0.name == "redirect_uri" ? URLQueryItem(name: $0.name, value: "https://example.net/cb") : $0 }
        }), "the finish step must come back to this Mac")
        #expect(!GoogleConsentLink.isValid(altered {
            $0.queryItems = ($0.queryItems ?? []) + [URLQueryItem(name: "include_granted_scopes", value: "true")]
        }), "never a folded grant")
    }
}

private struct FakeTokenTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw OAuthError.cancelled }
}

private struct NeverReceiver: LoopbackRedirectReceiver {
    func start() async throws -> URL { URL(string: "http://127.0.0.1:53682/oauth2callback")! }
    func waitForCallback(timeout: Duration, successHTML: String) async throws -> URLComponents { throw OAuthError.cancelled }
    func stop() async {}
}

private struct NoBrowser: ExternalBrowser {
    func open(_ url: URL) async throws {}
}
