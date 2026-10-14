import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanGmail

@Suite struct OAuthFlowManualTests {
    private func googleFake(scope: String = GmailScope.readonly) -> ScriptedTransport {
        ScriptedTransport { request in
            if request.url.host == "oauth2.example.invalid" {
                return jsonResponse(200, ["access_token": "synthetic-access-1", "expires_in": 3599,
                                          "refresh_token": "synthetic-refresh-1", "scope": scope])
            }
            if request.url.path == "/gmail/v1/users/me/profile" {
                return jsonResponse(200, ["emailAddress": "Someone@Example.COM", "historyId": "42"])
            }
            return jsonResponse(404, [:])
        }
    }

    private func flow(_ transport: ScriptedTransport, mode: SafeMode = .readOnly,
                      receiver: FakeReceiver = FakeReceiver(), browser: FakeBrowser = FakeBrowser()) -> OAuthFlow {
        OAuthFlow(client: Synthetic.client, mode: mode, transport: transport, receiver: receiver, browser: browser,
                  clock: TestClock())
    }

    private static let redirect = URL(string: "http://127.0.0.1:53999/oauth2callback")!

    private func pasted(_ session: OAuthFlow.ManualAuthorization, query: String,
                        base: String = "http://127.0.0.1:53999/oauth2callback") -> String {
        "\(base)?\(query)"
    }

    @Test func beginManualUsesALoopbackRedirectAndCarriesTheLoginHint() throws {
        let f = flow(ScriptedTransport())
        let session = try f.beginManual(loginHint: "me@example.com")
        let redirect = try #require(URLComponents(url: session.redirectURI, resolvingAgainstBaseURL: false))
        #expect(redirect.scheme == "http" && redirect.host == "127.0.0.1" && redirect.path == "/oauth2callback")
        #expect((49152...65535).contains(redirect.port ?? 0))
        #expect(queryValue(session.url, "redirect_uri") == session.redirectURI.absoluteString)
        #expect(queryValue(session.url, "state") == session.state)
        #expect(queryValue(session.url, "code_challenge") == PKCE.challenge(for: session.verifier))
        #expect(queryValue(session.url, "login_hint") == "me@example.com")
        #expect(queryValue(session.url, "scope") == GmailScope.readonly)
        #expect(queryValue(session.url, "include_granted_scopes") == nil)
        let text = "\(session)"
        #expect(!text.contains(session.verifier) && !text.contains(session.state))
        #expect(OAuthFlow.manualRedirectURI(port: 50123).absoluteString == "http://127.0.0.1:50123/oauth2callback")
    }

    @Test func manualRedirectMustBeAPlainLoopbackAddress() async throws {
        let transport = googleFake()
        let f = flow(transport)
        for bad in ["https://127.0.0.1:5000/oauth2callback", "http://localhost:5000/oauth2callback",
                    "http://127.0.0.2:5000/oauth2callback", "http://evil.example:5000/oauth2callback",
                    "http://127.0.0.1/oauth2callback", "http://127.0.0.1:5000/", "http://127.0.0.1:5000/cb?x=1",
                    "http://127.0.0.1:5000/cb#f", "http://u:p@127.0.0.1:5000/cb"] {
            let url = try #require(URL(string: bad))
            #expect(throws: OAuthError.denied("invalid_redirect_uri"), "\(bad)") { _ = try f.beginManual(redirectURI: url) }
            await #expect(throws: OAuthError.denied("invalid_redirect_uri"), "\(bad)") {
                _ = try await f.completeManual(pastedURL: url, verifier: "v", state: "s", redirectURI: url)
            }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func thePastedAddressMustBeExactlyTheRedirect() async throws {
        let transport = googleFake()
        let f = flow(transport)
        let session = try f.beginManual(redirectURI: Self.redirect)
        let query = "code=c&state=\(session.state)"
        for base in ["http://127.0.0.1:53998/oauth2callback", "http://localhost:53999/oauth2callback",
                     "http://127.0.0.2:53999/oauth2callback", "https://127.0.0.1:53999/oauth2callback",
                     "http://evil.example:53999/oauth2callback", "http://127.0.0.1:53999/other",
                     "http://127.0.0.1:53999/oauth2callback/", "http://user@127.0.0.1:53999/oauth2callback"] {
            await #expect(throws: OAuthError.denied("redirect_mismatch"), "\(base)") {
                _ = try await f.completeManual(pasted: pasted(session, query: query, base: base), session)
            }
        }
        await #expect(throws: OAuthError.denied("redirect_mismatch")) {
            let url = try #require(URL(string: pasted(session, query: query) + "#fragment"))
            _ = try await f.completeManual(pastedURL: url, verifier: session.verifier, state: session.state,
                                           redirectURI: session.redirectURI)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func pastedAddressesAreDecodedOnceAndEverythingElseIsIgnored() async throws {
        let base = "127.0.0.1:53999/oauth2callback"
        func cases(_ state: String) -> [(String, String)] {
            [
                ("http://\(base)?state=\(state)&code=4%2F0SyntheticAbc_-d", "4/0SyntheticAbc_-d"),
                ("http://\(base)?code=4%2F0SyntheticAbc_-d&state=\(state)&scope=https://www.googleapis.com/auth/gmail.readonly",
                 "4/0SyntheticAbc_-d"),
                ("http://\(base)?state=\(state)&code=4/0Literal&scope=email%20profile&authuser=0&prompt=consent",
                 "4/0Literal"),
                ("http://\(base)?state=\(state)&code=c1   \n", "c1"),
                ("http://\(base)?state=\(state)&code=c1 &scope=a b\nmore text", "c1"),
                ("\"http://\(base)?state=\(state)&code=c2\"", "c2"),
                ("[http://\(base)?state=\(state)&code=c3]", "c3"),
                ("(http://\(base)?state=\(state)&code=c4).", "c4"),
                ("<http://\(base)?state=\(state)&code=c5>,", "c5"),
                ("\u{201C}http://\(base)?state=\(state)&code=c6\u{201D}", "c6"),
                ("\(base)?state=\(state)&code=c7", "c7"),
                ("http://\(base)?state=\(state)&code=c8#frag&code=evil", "c8"),
                ("HTTP://\(base)?state=\(state)&code=c9", "c9"),
                ("http://\(base)?state=\(state)&code=4%252Fx", "4%2Fx"),
            ]
        }
        let n = cases("s").count
        for index in 0..<n {
            let transport = googleFake()
            let f = flow(transport)
            let session = try f.beginManual(redirectURI: Self.redirect)
            let (text, expected) = cases(session.state)[index]
            _ = try await f.completeManual(pasted: text, session)
            let form = formFields(transport.requests[0].body)
            #expect(form["code"] == expected, "case \(index)")
            #expect(form["client_secret"] == Synthetic.client.clientSecret, "case \(index)")
            #expect(form["scope"] == nil)
        }
    }

    @Test func pastedTextIsTrimmedAndAHiddenSchemeIsRestored() async throws {
        for wrap in ["  \"%@\"\n", "<%@>", "'%@'", "%@"] {
            let transport = googleFake()
            let f = flow(transport)
            let session = try f.beginManual(redirectURI: Self.redirect)
            let text = wrap.replacingOccurrences(of: "%@", with: pasted(session, query: "code=manual&state=\(session.state)"))
            let result = try await f.completeManual(pasted: text, session)
            #expect(result.email == "someone@example.com")
            #expect(formFields(transport.requests[0].body)["code"] == "manual")
            #expect(formFields(transport.requests[0].body)["code_verifier"] == session.verifier)
            #expect(formFields(transport.requests[0].body)["redirect_uri"] == Self.redirect.absoluteString)
        }
        let transport = googleFake()
        let f = flow(transport)
        let session = try f.beginManual(redirectURI: Self.redirect)
        _ = try await f.completeManual(pasted: "127.0.0.1:53999/oauth2callback?state=\(session.state)&code=c2", session)
        #expect(formFields(transport.requests[0].body)["code"] == "c2")
    }

    @Test func aBareCodeOrGarbageIsRefusedBeforeAnyRequest() async throws {
        let transport = googleFake()
        let f = flow(transport)
        let session = try f.beginManual(redirectURI: Self.redirect)
        for text in ["4/0AbCdEf-synthetic-code", "", "   ", "code=c&state=\(session.state)", "not a url at all"] {
            await #expect(throws: OAuthError.denied("manual_paste_not_a_redirect_url"), "\(text)") {
                _ = try await f.completeManual(pasted: text, session)
            }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func repeatedCallbackParametersAreRefused() async throws {
        let transport = googleFake()
        let f = flow(transport)
        let session = try f.beginManual(redirectURI: Self.redirect)
        let s = session.state
        for query in ["state=\(s)&state=forged&code=c", "state=forged&state=\(s)&code=c", "state=\(s)&state=\(s)&code=c"] {
            await #expect(throws: OAuthError.stateMismatch, "\(query)") {
                _ = try await f.completeManual(pasted: pasted(session, query: query), session)
            }
        }
        for query in ["state=\(s)&code=a&code=b", "state=\(s)&error=access_denied&error=x"] {
            await #expect(throws: OAuthError.denied("invalid_callback"), "\(query)") {
                _ = try await f.completeManual(pasted: pasted(session, query: query), session)
            }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func onlyOAuthErrorCodesArePassedOn() async throws {
        let f = flow(googleFake())
        let session = try f.beginManual(redirectURI: Self.redirect)
        await #expect(throws: OAuthError.denied("access_denied")) {
            _ = try await f.completeManual(pasted: pasted(session, query: "error=access_denied&state=\(session.state)"),
                                           session)
        }
        await #expect(throws: OAuthError.denied("invalid_callback")) {
            _ = try await f.completeManual(pasted: pasted(session, query: "error=%3Cscript%3E&state=\(session.state)"),
                                           session)
        }
        #expect(OAuthFlow.isErrorCode("admin_policy_enforced"))
        #expect(!OAuthFlow.isErrorCode("Access Denied") && !OAuthFlow.isErrorCode(String(repeating: "a", count: 65)))
    }

    @Test func theManualFlowKeepsTheReadOnlyScopeGuard() async throws {
        let transport = googleFake(scope: "\(GmailScope.readonly) \(GmailScope.modify)")
        let f = flow(transport)
        let session = try f.beginManual(redirectURI: Self.redirect)
        do {
            _ = try await f.completeManual(pasted: pasted(session, query: "code=c&state=\(session.state)"), session)
            Issue.record("expected a refusal")
        } catch let OAuthError.denied(reason) {
            #expect(reason.hasPrefix("read-only sign-in refused"))
        }
        #expect(transport.requests.count == 1)
    }

    @Test func authorizeAnnouncesItsStateToTheReceiverBeforeTheBrowserOpens() async throws {
        let receiver = FakeReceiver()
        let announcedBeforeOpen = FakeBrowser { url in
            #expect(receiver.expectedStates == [queryValue(url, "state") ?? "missing"])
            var callback = URLComponents(url: receiver.redirect, resolvingAgainstBaseURL: false)!
            callback.queryItems = [URLQueryItem(name: "code", value: "c"),
                                   URLQueryItem(name: "state", value: queryValue(url, "state"))]
            receiver.deliver(callback)
        }
        let result = try await flow(googleFake(), receiver: receiver, browser: announcedBeforeOpen)
            .authorize(loginHint: nil, timeout: .seconds(300))
        #expect(result.email == "someone@example.com")
        #expect(receiver.expectedStates.count == 1)
    }
}
