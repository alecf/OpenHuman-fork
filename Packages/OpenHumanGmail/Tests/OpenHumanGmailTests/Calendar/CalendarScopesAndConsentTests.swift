import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanGmail

@Suite struct CalendarScopesTests {
    @Test func eachModeAsksForTheNarrowCalendarScopesOnly() {
        #expect(CalendarScopes.requested(for: .readOnly) == ["https://www.googleapis.com/auth/calendar.events.readonly",
                                                             "https://www.googleapis.com/auth/calendar.freebusy"])
        #expect(CalendarScopes.requested(for: .writeAllowlist) == CalendarScopes.requested(for: .readOnly),
                "write-allowlist never creates events")
        #expect(CalendarScopes.requested(for: .normal) == ["https://www.googleapis.com/auth/calendar.events",
                                                           "https://www.googleapis.com/auth/calendar.freebusy"])
        for mode in SafeMode.allCases {
            let scopes = CalendarScopes.requested(for: mode)
            #expect(!scopes.contains("https://www.googleapis.com/auth/calendar"), "never the full calendar scope")
            #expect(!scopes.contains(where: CalendarScopes.isMailScope), "never a Gmail scope")
            #expect(Set(scopes).isSubset(of: CalendarScopes.all))
        }
    }

    @Test func aGrantIsTheRequestExactlyIdentityScopesAside() throws {
        let read = CalendarScopes.requested(for: .readOnly)
        try CalendarScopes.check(granted: read, requested: read)
        try CalendarScopes.check(granted: read + ["openid", "email", "https://www.googleapis.com/auth/userinfo.email"],
                                 requested: read)
        let write = CalendarScopes.requested(for: .normal)
        try CalendarScopes.check(granted: write + [CalendarScope.eventsReadonly], requested: write)
        #expect(throws: OAuthError.insufficientScopes(missing: [CalendarScope.freebusy])) {
            try CalendarScopes.check(granted: [CalendarScope.eventsReadonly], requested: read)
        }
        for extra in [GmailScope.readonly, GmailScope.modify, "https://mail.google.com/",
                      "https://www.googleapis.com/auth/gmail.send", "https://www.googleapis.com/auth/calendar",
                      CalendarScope.events, "https://www.googleapis.com/auth/drive.readonly"] {
            #expect(throws: OAuthError.denied("calendar grant refused"), "\(extra)") {
                try CalendarScopes.check(granted: read + [extra], requested: read)
            }
            #expect(CalendarScopes.refusal(granted: read + [extra], requested: read) != nil)
        }
    }

    @Test func onlyAUsableGrantIsUsedAndOnlyWriteModeWrites() {
        let read = CalendarScopes.requested(for: .readOnly)
        let write = CalendarScopes.requested(for: .normal)
        #expect(CalendarScopes.isUsable(read) && CalendarScopes.isUsable(write))
        #expect(CalendarScopes.isUsable(write + ["openid"]))
        #expect(!CalendarScopes.isUsable([CalendarScope.eventsReadonly]), "free/busy is part of it")
        #expect(!CalendarScopes.isUsable(read + [GmailScope.readonly]), "a calendar token never carries a Gmail scope")
        #expect(!CalendarScopes.isUsable([]))
        #expect(CalendarScopes.allowsWrites(mode: .normal, granted: write))
        #expect(!CalendarScopes.allowsWrites(mode: .normal, granted: read), "a read grant never writes")
        #expect(!CalendarScopes.allowsWrites(mode: .readOnly, granted: write), "read-only never writes")
        #expect(!CalendarScopes.allowsWrites(mode: .writeAllowlist, granted: write), "write-allowlist never writes events")
        #expect(!CalendarScopes.allowsWrites(mode: .normal, granted: write + [GmailScope.modify]))
    }

    @Test func theGmailRulesAreExactlyAsTheyWere() throws {
        #expect(SafeMode.readOnly.oauthScopes == [GmailScope.readonly])
        #expect(SafeMode.normal.oauthScopes == [GmailScope.modify])
        let signIn = OAuthFlow(client: Synthetic.client, mode: .readOnly, transport: ScriptedTransport(),
                               receiver: FakeReceiver(), browser: FakeBrowser(), clock: TestClock())
        #expect(signIn.toleratedExtraScopes == OAuthScopes.identity)
        #expect(throws: OAuthError.self) { try signIn.checkGrantedScopes([GmailScope.readonly, CalendarScope.eventsReadonly]) }
        let write = OAuthFlow(client: Synthetic.client, mode: .normal, transport: ScriptedTransport(),
                              receiver: FakeReceiver(), browser: FakeBrowser(), clock: TestClock())
        #expect(throws: OAuthError.self) { try write.checkGrantedScopes([GmailScope.modify, CalendarScope.events]) }
        #expect(OAuthScopes.beyondGrant([GmailScope.readonly, CalendarScope.eventsReadonly, CalendarScope.freebusy],
                                        stored: [GmailScope.readonly]) == [CalendarScope.eventsReadonly, CalendarScope.freebusy])
        #expect(OAuthScopes.beyondGrant([GmailScope.modify, CalendarScope.events], stored: [GmailScope.modify])
                    == [CalendarScope.events])
        #expect(!OAuthScopes.carriesMailWrite(CalendarScopes.requested(for: .normal)))
    }

    @Test func theCalendarTokenItemIsItsOwnFamily() {
        #expect(GoogleCalendarAuth.keychainService == "dev.openhuman.mail.calendar.oauth.v1")
        #expect(GoogleCalendarAuth.keychainService != OHIdentifiers.keychainService)
    }
}

@Suite struct CalendarConsentTests {
    private static let me = "robin@example.com"

    private func tokenEndpoint(scope: String) -> ScriptedTransport {
        ScriptedTransport { _ in
            jsonResponse(200, ["access_token": "synthetic-access-cal", "expires_in": 3599,
                               "refresh_token": "synthetic-refresh-cal", "scope": scope, "token_type": "Bearer"])
        }
    }

    private func consenting(_ receiver: FakeReceiver) -> FakeBrowser {
        FakeBrowser { url in
            var callback = URLComponents(url: receiver.redirect, resolvingAgainstBaseURL: false)!
            callback.queryItems = [URLQueryItem(name: "code", value: "synthetic-code"),
                                   URLQueryItem(name: "state", value: queryValue(url, "state"))]
            receiver.deliver(callback)
        }
    }

    @Test func theConsentAsksForExactlyTheCalendarScopesAndMakesNoGmailCall() async throws {
        let read = CalendarScopes.requested(for: .readOnly)
        let endpoint = tokenEndpoint(scope: read.joined(separator: " "))
        let receiver = FakeReceiver()
        let browser = consenting(receiver)
        let clock = TestClock()
        let consent = CalendarConsent(client: Synthetic.client, mode: .readOnly, transport: endpoint, receiver: receiver,
                                      browser: browser, clock: clock)
        #expect(consent.scopes == read)
        let token = try await consent.authorize(account: Self.me, timeout: .seconds(300))
        #expect(token.grantedScopes == read)
        #expect(token.refreshToken == "synthetic-refresh-cal" && token.clientID == Synthetic.clientID)
        #expect(token.accessTokenExpiry == clock.now.addingTimeInterval(3599))
        let url = try #require(browser.openedURLs.first)
        #expect(queryValue(url, "scope") == read.joined(separator: " "))
        #expect(queryValue(url, "include_granted_scopes") == nil, "the Gmail grant is never folded in")
        #expect(queryValue(url, "login_hint") == Self.me)
        #expect(endpoint.requests.count == 1, "the token endpoint only: no Gmail profile call")
        #expect(endpoint.requests.first?.url == Synthetic.client.tokenURI)
        #expect(formFields(endpoint.requests.first?.body)["grant_type"] == "authorization_code")
        #expect(receiver.startCount == 1 && receiver.stopCount == 1)
    }

    @Test func writeModeAsksToCreateEventsToo() async throws {
        let write = CalendarScopes.requested(for: .normal)
        let receiver = FakeReceiver()
        let browser = consenting(receiver)
        let consent = CalendarConsent(client: Synthetic.client, mode: .normal,
                                      transport: tokenEndpoint(scope: write.joined(separator: " ")), receiver: receiver,
                                      browser: browser, clock: TestClock())
        let token = try await consent.authorize(account: Self.me, timeout: .seconds(300))
        #expect(token.grantedScopes == write.sorted())
        #expect(queryValue(try #require(browser.openedURLs.first), "scope") == write.joined(separator: " "))
    }

    @Test func aGrantCarryingAGmailScopeIsRefused() async throws {
        let read = CalendarScopes.requested(for: .readOnly)
        for extra in [GmailScope.readonly, GmailScope.modify, "https://mail.google.com/", "https://www.googleapis.com/auth/calendar"] {
            let receiver = FakeReceiver()
            let consent = CalendarConsent(client: Synthetic.client, mode: .readOnly,
                                          transport: tokenEndpoint(scope: (read + [extra]).joined(separator: " ")),
                                          receiver: receiver, browser: consenting(receiver), clock: TestClock())
            await #expect(throws: OAuthError.denied("calendar grant refused"), "\(extra)") {
                _ = try await consent.authorize(account: Self.me, timeout: .seconds(300))
            }
        }
    }

    @Test func aBoxLeftUntickedIsInsufficientScopes() async throws {
        let receiver = FakeReceiver()
        let consent = CalendarConsent(client: Synthetic.client, mode: .readOnly,
                                      transport: tokenEndpoint(scope: CalendarScope.eventsReadonly), receiver: receiver,
                                      browser: consenting(receiver), clock: TestClock())
        await #expect(throws: OAuthError.insufficientScopes(missing: [CalendarScope.freebusy])) {
            _ = try await consent.authorize(account: Self.me, timeout: .seconds(300))
        }
    }

    @Test func aCalendarRefreshThatComesBackBroaderIsNeverUsed() async throws {
        let clock = TestClock()
        let read = CalendarScopes.requested(for: .readOnly)
        let calendarTokens = InMemoryTokenStore([Self.me: Synthetic.token(refresh: "r-cal", access: "old",
                                                                          expiry: clock.now.addingTimeInterval(-1),
                                                                          scopes: read)])
        let endpoint = ScriptedTransport { _ in
            jsonResponse(200, ["access_token": "refreshed", "expires_in": 3600,
                               "scope": (read + [GmailScope.readonly]).joined(separator: " ")])
        }
        let events = EventLog()
        let credentials = AccountCredentials(store: calendarTokens, client: Synthetic.client, transport: endpoint,
                                             clock: clock, onEvent: events.sink)
        await #expect(throws: OAuthError.reauthRequired) {
            _ = try await credentials.tokenManager(for: Self.me).accessToken(forceRefresh: false)
        }
        #expect(try calendarTokens.load(account: Self.me) == nil)
        #expect(events.all == [.needsReauth(account: Self.me, reason: .broaderGrant)])
    }
}
