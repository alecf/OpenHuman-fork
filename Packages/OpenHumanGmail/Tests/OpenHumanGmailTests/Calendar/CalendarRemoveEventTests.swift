import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

@Suite struct CalendarRemoveEventTests {
    private static let me = "robin@example.com"
    private static let path = "/calendar/v3/calendars/robin@example.com/events/ev1"

    private func event(_ fields: [String: Any]) -> [String: Any] {
        var base: [String: Any] = ["id": "ev1", "status": "confirmed", "summary": "Planning",
                                   "start": ["dateTime": "2026-10-13T15:00:00-07:00"],
                                   "end": ["dateTime": "2026-10-13T15:30:00-07:00"]]
        for (key, value) in fields { base[key] = value }
        return base
    }

    private func client(_ http: FakeHTTPTransport, mode: SafeMode = .normal) -> GoogleCalendarClient {
        GoogleCalendarClient(calendarID: Self.me, mode: mode, grantedScopes: CalendarScopes.requested(for: mode),
                             tokens: StaticTokenProvider(token: "synthetic-cal-access"), transport: http,
                             clock: InstantClock(), timeZone: TimeZone(identifier: "America/Los_Angeles")!)
    }

    private func serve(_ http: FakeHTTPTransport, _ event: [String: Any]) {
        let answer = jsonResponse(200, event)
        http.on("GET", Self.path) { _ in answer }
        http.on("DELETE", Self.path) { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
    }

    private func methods(_ http: FakeHTTPTransport) -> [String] { http.requests.map(\.method) }

    @Test func anEventTheAccountOrganizesWithNoGuestsIsReadThenDeletedTellingNobody() async throws {
        let http = FakeHTTPTransport()
        serve(http, event(["organizer": ["email": Self.me, "self": true]]))
        try await client(http).removeEvent(id: "ev1", sendUpdates: .none)
        #expect(methods(http) == ["GET", "DELETE"], "the guard read the event first")
        let delete = try #require(http.requests.last)
        #expect(delete.url.query?.contains("sendUpdates=none") == true)
        #expect(http.requests.first?.headers["Authorization"] == delete.headers["Authorization"], "the guard's read carries the same token")
    }

    @Test func anEventWithGuestsIsDeletedOnlyWhenGoogleTellsThem() async throws {
        let guests: [String: Any] = ["organizer": ["self": true], "attendees": [
            ["email": Self.me, "self": true, "responseStatus": "accepted"],
            ["email": "sam@example.org", "responseStatus": "needsAction"]]]
        let silent = FakeHTTPTransport()
        serve(silent, event(guests))
        await #expect(throws: GoogleCalendarError.self) { try await client(silent).removeEvent(id: "ev1", sendUpdates: .none) }
        #expect(methods(silent) == ["GET"], "no delete reached the wire")

        let told = FakeHTTPTransport()
        serve(told, event(guests))
        try await client(told).removeEvent(id: "ev1", sendUpdates: .all)
        #expect(methods(told) == ["GET", "DELETE"])
        #expect(told.requests.last?.url.query?.contains("sendUpdates=all") == true)
    }

    @Test func anEventSomeoneElseOrganizesIsNeverDeleted() async {
        for fields in [
            event(["organizer": ["email": "pat@example.org"], "creator": ["email": Self.me, "self": true]]),
            event(["organizer": ["email": "pat@example.org"], "attendees": [["email": Self.me, "self": true]]]),
            event([:]),
            event(["creator": ["email": "pat@example.org"]]),
        ] {
            let http = FakeHTTPTransport()
            serve(http, fields)
            await #expect(throws: GoogleCalendarError.self) { try await client(http).removeEvent(id: "ev1", sendUpdates: .all) }
            #expect(methods(http) == ["GET"])
        }
    }

    @Test func aCreatorWithNoOrganizerFieldCountsAsTheOrganizer() async throws {
        let http = FakeHTTPTransport()
        serve(http, event(["creator": ["email": Self.me, "self": true]]))
        try await client(http).removeEvent(id: "ev1", sendUpdates: .none)
        #expect(methods(http) == ["GET", "DELETE"])
    }

    @Test func recurringSpecialAndCancelledEventsAreRefused() async {
        let own: [String: Any] = ["organizer": ["self": true]]
        func with(_ extra: [String: Any]) -> [String: Any] { event(own.merging(extra) { $1 }) }
        for fields in [
            with(["recurrence": ["RRULE:FREQ=WEEKLY"]]),
            with(["recurringEventId": "series1"]),
            with(["eventType": "birthday"]),
            with(["eventType": "outOfOffice"]),
            with(["status": "cancelled"]),
        ] {
            let http = FakeHTTPTransport()
            serve(http, fields)
            await #expect(throws: GoogleCalendarError.self) { try await client(http).removeEvent(id: "ev1", sendUpdates: .none) }
            #expect(methods(http) == ["GET"])
        }
    }

    @Test func aReadThatFailsMeansNoDelete() async {
        for response in [HTTPResponse(status: 404, headers: [:], body: Data()), HTTPResponse(status: 200, headers: [:], body: Data("not json".utf8))] {
            let http = FakeHTTPTransport()
            http.on("GET", Self.path) { _ in response }
            http.on("DELETE", Self.path) { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
            await #expect(throws: GoogleCalendarError.self) { try await client(http).removeEvent(id: "ev1", sendUpdates: .none) }
            #expect(!methods(http).contains("DELETE"))
        }
    }

    @Test func readOnlyAndTestWriteModesNeverReachTheWire() async {
        for mode in [SafeMode.readOnly, .writeAllowlist] {
            let http = FakeHTTPTransport()
            serve(http, event(["organizer": ["self": true]]))
            await #expect(throws: GoogleCalendarError.self) { try await client(http, mode: mode).removeEvent(id: "ev1", sendUpdates: .none) }
            #expect(http.requests.isEmpty, "\(mode): not even the guard's read")
        }
    }

    @Test func anotherCalendarOrWithoutSendUpdatesIsRefusedBeforeAnyRead() {
        let wire = ScriptedTransport()
        let calendar = CalendarGuardTransport(wrapping: wire, calendarID: Self.me, mode: .normal,
                                              grantedScopes: CalendarScopes.requested(for: .normal),
                                              verifiesOwnedEventRemoval: true)
        let other = HTTPRequest(method: "DELETE", url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/other@example.org/events/ev1?sendUpdates=none")!, headers: [:], body: nil)
        #expect(calendar.refusalReason(for: other) != nil)
        let bare = HTTPRequest(method: "DELETE", url: URL(string: "https://www.googleapis.com/calendar/v3" + "/calendars/robin@example.com/events/ev1")!, headers: [:], body: nil)
        #expect(calendar.refusalReason(for: bare) != nil)
    }

    @Test func theRuleIsOffUnlessTheGuardIsMadeWithIt() async {
        let wire = ScriptedTransport { _ in jsonResponse(200, ["organizer": ["self": true]]) }
        let plain = CalendarGuardTransport(wrapping: wire, calendarID: Self.me, mode: .normal,
                                           grantedScopes: CalendarScopes.requested(for: .normal))
        let marked = [CalendarGuardTransport.removalRuleHeader: CalendarGuardTransport.removalRuleValue]
        let delete = HTTPRequest(method: "DELETE", url: URL(string: "https://www.googleapis.com" + Self.path + "?sendUpdates=none")!, headers: marked, body: nil)
        await #expect(throws: TransportError.self) { _ = try await plain.send(delete) }
        #expect(wire.requests.isEmpty)
    }

    @Test func withoutTheMarkerAGuardWithTheRuleStillFollowsTheCreateUndoRules() async {
        let wire = ScriptedTransport { _ in jsonResponse(200, ["organizer": ["self": true]]) }
        let calendar = CalendarGuardTransport(wrapping: wire, calendarID: Self.me, mode: .normal,
                                              grantedScopes: CalendarScopes.requested(for: .normal), verifiesOwnedEventRemoval: true)
        let unmarked = HTTPRequest(method: "DELETE", url: URL(string: "https://www.googleapis.com" + Self.path + "?sendUpdates=none")!, headers: [:], body: nil)
        await #expect(throws: TransportError.self) { _ = try await calendar.send(unmarked) }
        #expect(wire.requests.isEmpty, "not even a read: only an event created here, as before")
    }

    @Test func theMarkerNeverReachesTheWire() async throws {
        let http = FakeHTTPTransport()
        serve(http, event(["organizer": ["self": true]]))
        try await client(http).removeEvent(id: "ev1", sendUpdates: .none)
        #expect(http.requests.allSatisfy { $0.headers[CalendarGuardTransport.removalRuleHeader] == nil })
    }
}
