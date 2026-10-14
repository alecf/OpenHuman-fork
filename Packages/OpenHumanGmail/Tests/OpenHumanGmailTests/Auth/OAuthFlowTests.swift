import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanGmail

@Suite struct OAuthFlowTests {
    private func googleFake(scope: String, email: String = "Someone@Example.COM",
                            tokenStatus: Int = 200, tokenBody: [String: Any]? = nil) -> ScriptedTransport {
        let tokenResponse = jsonResponse(tokenStatus, tokenBody ?? [
            "access_token": "synthetic-access-1", "expires_in": 3599, "refresh_token": "synthetic-refresh-1",
            "scope": scope, "token_type": "Bearer",
        ])
        let profileResponse = jsonResponse(200, ["emailAddress": email, "historyId": "42", "messagesTotal": 3,
                                                 "threadsTotal": 2])
        return ScriptedTransport { request in
            if request.url.host == "oauth2.example.invalid" { return tokenResponse }
            if request.url.path == "/gmail/v1/users/me/profile" { return profileResponse }
            return jsonResponse(404, [:])
        }
    }

    private func consenting(_ receiver: FakeReceiver, code: String = "synthetic-code",
                            state override: String? = nil, extra: [URLQueryItem] = []) -> FakeBrowser {
        FakeBrowser { url in
            var callback = URLComponents(url: receiver.redirect, resolvingAgainstBaseURL: false)!
            callback.queryItems = [URLQueryItem(name: "code", value: code),
                                   URLQueryItem(name: "state", value: override ?? queryValue(url, "state"))] + extra
            receiver.deliver(callback)
        }
    }

    private func flow(_ mode: SafeMode, transport: ScriptedTransport, receiver: FakeReceiver = FakeReceiver(),
                      browser: FakeBrowser = FakeBrowser(), clock: TestClock = TestClock()) -> OAuthFlow {
        OAuthFlow(client: Synthetic.client, mode: mode, transport: transport, receiver: receiver, browser: browser,
                  clock: clock)
    }

    @Test func readOnlyModeRequestsExactlyGmailReadonlyAndNoEarlierGrants() {
        let f = flow(.readOnly, transport: ScriptedTransport())
        #expect(f.scopes == ["https://www.googleapis.com/auth/gmail.readonly"])
        #expect(f.scopes == SafeMode.readOnly.oauthScopes)
        #expect(f.isReadOnlyProfile)
        let url = f.authorizationURL(redirectURI: URL(string: "http://127.0.0.1:5000/oauth2callback")!,
                                     challenge: "chal", state: "st", loginHint: nil)
        #expect(url.host == "accounts.example.invalid")
        #expect(queryValue(url, "scope") == "https://www.googleapis.com/auth/gmail.readonly")
        #expect(queryValue(url, "include_granted_scopes") == nil)
        #expect(queryValue(url, "response_type") == "code")
        #expect(queryValue(url, "client_id") == Synthetic.clientID)
        #expect(queryValue(url, "redirect_uri") == "http://127.0.0.1:5000/oauth2callback")
        #expect(queryValue(url, "code_challenge") == "chal")
        #expect(queryValue(url, "code_challenge_method") == "S256")
        #expect(queryValue(url, "state") == "st")
        #expect(queryValue(url, "access_type") == "offline")
        #expect(queryValue(url, "prompt") == "consent")
        #expect(queryValue(url, "login_hint") == nil)
        #expect(!url.absoluteString.contains(Synthetic.clientSecret))
    }

    // Why: the client may hold broader grants from other tools, so the write profile asks for exactly gmail.modify
    @Test func normalAndWriteAllowlistRequestExactlyGmailModifyAndNoEarlierGrants() {
        for mode in [SafeMode.normal, .writeAllowlist] {
            let f = flow(mode, transport: ScriptedTransport())
            #expect(f.scopes == ["https://www.googleapis.com/auth/gmail.modify"])
            #expect(!f.isReadOnlyProfile)
            let url = f.authorizationURL(redirectURI: URL(string: "http://127.0.0.1:5000/oauth2callback")!,
                                         challenge: "c", state: "s", loginHint: "first+tag@example.com")
            #expect(queryValue(url, "scope") == "https://www.googleapis.com/auth/gmail.modify")
            #expect(queryValue(url, "include_granted_scopes") == nil)
            #expect(queryValue(url, "login_hint") == "first+tag@example.com")
            #expect(url.absoluteString.contains("login_hint=first%2Btag@example.com"))
        }
    }

    @Test func readOnlyAuthorizeHappyPath() async throws {
        let transport = googleFake(scope: GmailScope.readonly)
        let receiver = FakeReceiver()
        let browser = consenting(receiver)
        let clock = TestClock()
        let result = try await flow(.readOnly, transport: transport, receiver: receiver, browser: browser, clock: clock)
            .authorize(loginHint: nil, timeout: .seconds(300))

        #expect(result.email == "someone@example.com")
        #expect(result.token.grantedScopes == [GmailScope.readonly])
        #expect(result.token.refreshToken == "synthetic-refresh-1")
        #expect(result.token.accessToken == "synthetic-access-1")
        #expect(result.token.accessTokenExpiry == clock.now.addingTimeInterval(3599))
        #expect(result.token.clientID == Synthetic.clientID)
        #expect(result.profile.historyId == "42")
        #expect(receiver.startCount == 1 && receiver.stopCount == 1)
        #expect(browser.openedURLs.count == 1)

        let requests = transport.requests
        #expect(requests.count == 2)
        let exchange = requests[0]
        #expect(exchange.method == "POST")
        #expect(exchange.url == Synthetic.client.tokenURI)
        #expect(exchange.headers["Content-Type"] == "application/x-www-form-urlencoded")
        let form = formFields(exchange.body)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "synthetic-code")
        #expect(form["client_id"] == Synthetic.clientID)
        #expect(form["client_secret"] == Synthetic.clientSecret)
        #expect(form["redirect_uri"] == receiver.redirect.absoluteString)
        let challenge = queryValue(browser.openedURLs[0], "code_challenge")
        #expect(form["code_verifier"].map(PKCE.challenge(for:)) == challenge)
        #expect(form["code_verifier"]?.count == 86)

        let profile = requests[1]
        #expect(profile.method == "GET")
        #expect(profile.url.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/profile")
        #expect(profile.headers["Authorization"] == "Bearer synthetic-access-1")
    }

    @Test func stateMismatchStopsBeforeAnyRequest() async throws {
        let transport = googleFake(scope: GmailScope.readonly)
        let receiver = FakeReceiver()
        let f = flow(.readOnly, transport: transport, receiver: receiver,
                     browser: consenting(receiver, state: "forged-state"))
        await #expect(throws: OAuthError.stateMismatch) { _ = try await f.authorize(loginHint: nil, timeout: .seconds(300)) }
        #expect(transport.requests.isEmpty)
        #expect(receiver.stopCount == 1)
    }

    @Test func missingStateIsAStateMismatchEvenWithAnError() async throws {
        let transport = googleFake(scope: GmailScope.readonly)
        let receiver = FakeReceiver()
        let browser = FakeBrowser { _ in
            receiver.deliver(URLComponents(string: "http://127.0.0.1:53682/oauth2callback?error=access_denied")!)
        }
        let f = flow(.readOnly, transport: transport, receiver: receiver, browser: browser)
        await #expect(throws: OAuthError.stateMismatch) { _ = try await f.authorize(loginHint: nil, timeout: .seconds(300)) }
        #expect(transport.requests.isEmpty)
    }

    @Test func deniedConsentMapsToDenied() async throws {
        let transport = googleFake(scope: GmailScope.readonly)
        let receiver = FakeReceiver()
        let browser = FakeBrowser { url in
            var c = URLComponents(url: receiver.redirect, resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "error", value: "access_denied"),
                            URLQueryItem(name: "state", value: queryValue(url, "state"))]
            receiver.deliver(c)
        }
        let f = flow(.readOnly, transport: transport, receiver: receiver, browser: browser)
        await #expect(throws: OAuthError.denied("access_denied")) {
            _ = try await f.authorize(loginHint: nil, timeout: .seconds(300))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func timesOutOnTheInjectedClock() async throws {
        let transport = googleFake(scope: GmailScope.readonly)
        let receiver = FakeReceiver()
        let clock = TestClock()
        let f = flow(.readOnly, transport: transport, receiver: receiver, browser: FakeBrowser(), clock: clock)
        let task = Task { try await f.authorize(loginHint: nil, timeout: .seconds(300)) }
        #expect(await eventually { clock.sleeperCount == 1 })
        #expect(clock.nextDeadline == clock.now.addingTimeInterval(300))
        clock.advance(by: .seconds(300))
        await #expect(throws: OAuthError.timedOut) { _ = try await task.value }
        #expect(transport.requests.isEmpty)
        #expect(receiver.stopCount == 1)
    }

    @Test func cancellationIsReportedAsCancelled() async throws {
        let receiver = FakeReceiver()
        let clock = TestClock()
        let f = flow(.readOnly, transport: ScriptedTransport(), receiver: receiver, browser: FakeBrowser(), clock: clock)
        let task = Task { try await f.authorize(loginHint: nil, timeout: .seconds(300)) }
        #expect(await eventually { clock.sleeperCount == 1 })
        task.cancel()
        await #expect(throws: OAuthError.cancelled) { _ = try await task.value }
        #expect(receiver.stopCount == 1)
    }

    @Test func browserFailureStopsTheReceiver() async throws {
        struct BrowserDown: Error {}
        let receiver = FakeReceiver()
        let f = flow(.readOnly, transport: ScriptedTransport(), receiver: receiver,
                     browser: FakeBrowser { _ in throw BrowserDown() })
        await #expect(throws: BrowserDown.self) { _ = try await f.authorize(loginHint: nil, timeout: .seconds(300)) }
        #expect(receiver.stopCount == 1)
    }

    @Test func normalModeRejectsAReadonlyOnlyGrant() async throws {
        let transport = googleFake(scope: GmailScope.readonly)
        let receiver = FakeReceiver()
        let f = flow(.normal, transport: transport, receiver: receiver, browser: consenting(receiver))
        await #expect(throws: OAuthError.insufficientScopes(missing: [GmailScope.modify])) {
            _ = try await f.authorize(loginHint: nil, timeout: .seconds(300))
        }
        #expect(transport.requests.count == 1)
    }

    @Test func readOnlyModeRefusesATokenCarryingWriteScopes() async throws {
        let transport = googleFake(scope: "\(GmailScope.readonly) \(GmailScope.modify)")
        let receiver = FakeReceiver()
        let f = flow(.readOnly, transport: transport, receiver: receiver, browser: consenting(receiver))
        do {
            _ = try await f.authorize(loginHint: nil, timeout: .seconds(300))
            Issue.record("expected a refusal")
        } catch let OAuthError.denied(reason) {
            #expect(reason.contains("read-only"))
        }
        #expect(transport.requests.count == 1)
    }

    @Test func normalModeRefusesATokenCarryingBroaderScopes() async throws {
        for broader in ["https://mail.google.com/", "https://www.googleapis.com/auth/gmail.settings.basic",
                        "https://www.googleapis.com/auth/gmail.send", "https://www.googleapis.com/auth/calendar"] {
            let transport = googleFake(scope: "\(GmailScope.modify) \(broader)")
            let receiver = FakeReceiver()
            let f = flow(.normal, transport: transport, receiver: receiver, browser: consenting(receiver))
            do {
                _ = try await f.authorize(loginHint: nil, timeout: .seconds(300))
                Issue.record("expected a refusal for \(broader)")
            } catch let OAuthError.denied(reason) {
                #expect(reason.hasPrefix("write sign-in refused"), "\(broader)")
            }
            #expect(transport.requests.count == 1, "the exchange only; no profile call")
        }
        let tolerated = googleFake(scope: "openid \(GmailScope.readonly) \(GmailScope.modify)")
        let receiver = FakeReceiver()
        let result = try await flow(.normal, transport: tolerated, receiver: receiver, browser: consenting(receiver))
            .authorize(loginHint: nil, timeout: .seconds(300))
        #expect(result.token.grantedScopes.contains(GmailScope.modify))
    }

    @Test func readOnlyModeToleratesIdentityScopes() async throws {
        let transport = googleFake(scope: "openid \(GmailScope.readonly) https://www.googleapis.com/auth/userinfo.email")
        let receiver = FakeReceiver()
        let result = try await flow(.readOnly, transport: transport, receiver: receiver, browser: consenting(receiver))
            .authorize(loginHint: nil, timeout: .seconds(300))
        #expect(result.token.grantedScopes.contains(GmailScope.readonly))
    }

    @Test func tokenEndpointErrorsMapToTokenEndpoint() async throws {
        let receiver = FakeReceiver()
        let failing = googleFake(scope: "", tokenStatus: 400,
                                 tokenBody: ["error": "invalid_grant", "error_description": "Bad Request"])
        await #expect(throws: OAuthError.tokenEndpoint(status: 400, error: "invalid_grant", description: "Bad Request")) {
            _ = try await flow(.readOnly, transport: failing, receiver: receiver, browser: consenting(receiver))
                .authorize(loginHint: nil, timeout: .seconds(300))
        }
        let receiver2 = FakeReceiver()
        let noRefresh = googleFake(scope: GmailScope.readonly, tokenBody: [
            "access_token": "synthetic-access-1", "expires_in": 3599, "scope": GmailScope.readonly,
        ])
        await #expect(throws: OAuthError.tokenEndpoint(status: 200, error: "missing_refresh_token", description: nil)) {
            _ = try await flow(.readOnly, transport: noRefresh, receiver: receiver2, browser: consenting(receiver2))
                .authorize(loginHint: nil, timeout: .seconds(300))
        }
    }

    @Test func manualFlowRoundTrip() async throws {
        let transport = googleFake(scope: GmailScope.readonly)
        let f = flow(.readOnly, transport: transport)
        let redirect = URL(string: "http://127.0.0.1:1/oauth2callback")!
        let (url, verifier, state) = f.manualAuthorizationURL(redirectURI: redirect)
        #expect(queryValue(url, "state") == state)
        #expect(queryValue(url, "code_challenge") == PKCE.challenge(for: verifier))
        #expect(queryValue(url, "scope") == GmailScope.readonly)

        let forged = URL(string: "http://127.0.0.1:1/oauth2callback?code=c&state=forged")!
        await #expect(throws: OAuthError.stateMismatch) {
            _ = try await f.completeManual(pastedURL: forged, verifier: verifier, state: state, redirectURI: redirect)
        }
        #expect(transport.requests.isEmpty)

        let pasted = URL(string: "http://127.0.0.1:1/oauth2callback?code=manual-code&state=\(state)")!
        let result = try await f.completeManual(pastedURL: pasted, verifier: verifier, state: state, redirectURI: redirect)
        #expect(result.email == "someone@example.com")
        #expect(formFields(transport.requests[0].body)["code"] == "manual-code")
        #expect(formFields(transport.requests[0].body)["code_verifier"] == verifier)
    }

    @Test func apiTransportIsReadOnly() async throws {
        let transport = ScriptedTransport()
        let f = flow(.normal, transport: transport)
        #expect(f.apiTransport is ReadOnlyTransport)
        let write = HTTPRequest(method: "POST", url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!,
                                headers: [:])
        await #expect(throws: TransportError.blockedBySafeMode("POST /gmail/v1/users/me/messages/send")) {
            _ = try await f.apiTransport.send(write)
        }
        #expect(transport.requests.isEmpty)
    }
}
