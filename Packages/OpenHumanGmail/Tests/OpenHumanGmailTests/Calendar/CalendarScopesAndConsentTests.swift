import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanGmail

@Suite struct CalendarScopesTests {
    @Test func theRequestIsTheNarrowCalendarScopesOnly() {
        #expect(CalendarScopes.request.write == ["https://www.googleapis.com/auth/calendar.events",
                                                 "https://www.googleapis.com/auth/calendar.freebusy"])
        #expect(CalendarScopes.request.read == ["https://www.googleapis.com/auth/calendar.events.readonly",
                                                "https://www.googleapis.com/auth/calendar.freebusy"])
        for scopes in [CalendarScopes.request.write, CalendarScopes.request.read] {
            #expect(!scopes.contains("https://www.googleapis.com/auth/calendar"), "never the full calendar scope")
            #expect(!scopes.contains(where: CalendarScopes.isMailScope), "never a Gmail scope")
            #expect(Set(scopes).isSubset(of: CalendarScopes.all))
        }
    }

    @Test func aGrantIsTheRequestExactlyIdentityScopesAside() throws {
        let read = CalendarScopes.request.read
        try CalendarScopes.check(granted: read, requested: read)
        try CalendarScopes.check(granted: read + ["openid", "email", "https://www.googleapis.com/auth/userinfo.email"],
                                 requested: read)
        let write = CalendarScopes.request.write
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

    @Test func onlyAUsableGrantIsUsedAndOnlyAWriteGrantWrites() {
        let read = CalendarScopes.request.read
        let write = CalendarScopes.request.write
        #expect(CalendarScopes.isUsable(read) && CalendarScopes.isUsable(write))
        #expect(CalendarScopes.isUsable(write + ["openid"]))
        #expect(!CalendarScopes.isUsable([CalendarScope.eventsReadonly]), "free/busy is part of it")
        #expect(!CalendarScopes.isUsable(read + [GmailScope.readonly]), "a calendar token never carries a Gmail scope")
        #expect(!CalendarScopes.isUsable([]))
        #expect(CalendarScopes.allowsWrites(granted: write))
        #expect(CalendarScopes.allowsWrites(granted: write + ["openid"]))
        #expect(!CalendarScopes.allowsWrites(granted: read), "a read grant never writes")
        #expect(!CalendarScopes.allowsWrites(granted: [CalendarScope.events]), "an unusable grant never writes")
        #expect(!CalendarScopes.allowsWrites(granted: write + [GmailScope.modify]))
    }

    @Test func theGmailRulesAreExactlyAsTheyWere() throws {
        #expect(OAuthScopes.mailRequest == [GmailScope.modify])
        let signIn = OAuthFlow(client: Synthetic.client, scopes: OAuthScopes.mailRequest, transport: ScriptedTransport(),
                               receiver: FakeReceiver(), browser: FakeBrowser(), clock: TestClock())
        #expect(signIn.toleratedExtraScopes == OAuthScopes.identity.union([GmailScope.readonly]))
        #expect(throws: OAuthError.self) { try signIn.checkGrantedScopes([GmailScope.modify, CalendarScope.events]) }
        #expect(throws: OAuthError.self) { try signIn.checkGrantedScopes([GmailScope.modify, CalendarScope.eventsReadonly]) }
        #expect(OAuthScopes.beyondGrant([GmailScope.readonly, CalendarScope.eventsReadonly, CalendarScope.freebusy],
                                        stored: [GmailScope.readonly]) == [CalendarScope.eventsReadonly, CalendarScope.freebusy])
        #expect(OAuthScopes.beyondGrant([GmailScope.modify, CalendarScope.events], stored: [GmailScope.modify])
                    == [CalendarScope.events])
        #expect(!OAuthScopes.carriesMailWrite(CalendarScopes.request.write))
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
        let write = CalendarScopes.request.write
        let endpoint = tokenEndpoint(scope: write.joined(separator: " "))
        let receiver = FakeReceiver()
        let browser = consenting(receiver)
        let clock = TestClock()
        let consent = CalendarConsent(client: Synthetic.client, transport: endpoint, receiver: receiver,
                                      browser: browser, clock: clock)
        #expect(consent.scopes == write)
        let token = try await consent.authorize(account: Self.me, timeout: .seconds(300))
        #expect(token.grantedScopes == write)
        #expect(token.refreshToken == "synthetic-refresh-cal" && token.clientID == Synthetic.clientID)
        #expect(token.accessTokenExpiry == clock.now.addingTimeInterval(3599))
        let url = try #require(browser.openedURLs.first)
        #expect(queryValue(url, "scope") == write.joined(separator: " "))
        #expect(queryValue(url, "include_granted_scopes") == nil, "the Gmail grant is never folded in")
        #expect(queryValue(url, "login_hint") == Self.me)
        #expect(endpoint.requests.count == 1, "the token endpoint only: no Gmail profile call")
        #expect(endpoint.requests.first?.url == Synthetic.client.tokenURI)
        #expect(formFields(endpoint.requests.first?.body)["grant_type"] == "authorization_code")
        #expect(receiver.startCount == 1 && receiver.stopCount == 1)
    }

    @Test func theConsentAlwaysAsksToCreateEvents() async throws {
        let write = CalendarScopes.request.write
        let receiver = FakeReceiver()
        let browser = consenting(receiver)
        let consent = CalendarConsent(client: Synthetic.client,
                                      transport: tokenEndpoint(scope: write.joined(separator: " ")), receiver: receiver,
                                      browser: browser, clock: TestClock())
        #expect(consent.scopes.contains(CalendarScope.events) && !consent.scopes.contains(CalendarScope.eventsReadonly))
        let token = try await consent.authorize(account: Self.me, timeout: .seconds(300))
        #expect(token.grantedScopes == write.sorted())
        #expect(CalendarScopes.allowsWrites(granted: token.grantedScopes))
        #expect(queryValue(try #require(browser.openedURLs.first), "scope") == write.joined(separator: " "))
    }

    @Test func aGrantCarryingAGmailScopeIsRefused() async throws {
        let write = CalendarScopes.request.write
        for extra in [GmailScope.readonly, GmailScope.modify, "https://mail.google.com/", "https://www.googleapis.com/auth/calendar"] {
            let receiver = FakeReceiver()
            let consent = CalendarConsent(client: Synthetic.client,
                                          transport: tokenEndpoint(scope: (write + [extra]).joined(separator: " ")),
                                          receiver: receiver, browser: consenting(receiver), clock: TestClock())
            await #expect(throws: OAuthError.denied("calendar grant refused"), "\(extra)") {
                _ = try await consent.authorize(account: Self.me, timeout: .seconds(300))
            }
        }
    }

    @Test func aBoxLeftUntickedIsInsufficientScopes() async throws {
        let receiver = FakeReceiver()
        let consent = CalendarConsent(client: Synthetic.client,
                                      transport: tokenEndpoint(scope: CalendarScope.events), receiver: receiver,
                                      browser: consenting(receiver), clock: TestClock())
        await #expect(throws: OAuthError.insufficientScopes(missing: [CalendarScope.freebusy])) {
            _ = try await consent.authorize(account: Self.me, timeout: .seconds(300))
        }
    }

    @Test func aCalendarRefreshThatComesBackBroaderIsNeverUsed() async throws {
        let clock = TestClock()
        let write = CalendarScopes.request.write
        let calendarTokens = InMemoryTokenStore([Self.me: Synthetic.token(refresh: "r-cal", access: "old",
                                                                          expiry: clock.now.addingTimeInterval(-1),
                                                                          scopes: write)])
        let endpoint = ScriptedTransport { _ in
            jsonResponse(200, ["access_token": "refreshed", "expires_in": 3600,
                               "scope": (write + [GmailScope.readonly]).joined(separator: " ")])
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
