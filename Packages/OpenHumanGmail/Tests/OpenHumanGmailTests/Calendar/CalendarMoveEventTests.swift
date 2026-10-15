import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

private let zone = TimeZone(identifier: "America/Los_Angeles")!

private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

@Suite struct CalendarMoveEventTests {
    private static let me = "robin@example.com"
    private static let event = "https://www.googleapis.com/calendar/v3/calendars/robin@example.com/events/ev1"

    private func patch(_ url: String, _ body: [String: Any]) -> HTTPRequest {
        HTTPRequest(method: "PATCH", url: URL(string: url)!, headers: [:],
                    body: try! JSONSerialization.data(withJSONObject: body))
    }

    private func guardFor(_ scopes: [String] = CalendarScopes.request.write) -> CalendarGuardTransport {
        CalendarGuardTransport(wrapping: ScriptedTransport(), calendarID: Self.me, grantedScopes: scopes)
    }

    private let times: [String: Any] = ["start": ["dateTime": "2026-10-13T15:00:00-07:00"],
                                        "end": ["dateTime": "2026-10-13T15:30:00-07:00"]]

    @Test func aTimeOnlyPatchPassesOnlyWithCalendarEvents() {
        let move = patch(Self.event + "?sendUpdates=all", times)
        #expect(guardFor().refusalReason(for: move) == nil)
        #expect(guardFor(CalendarScopes.request.read).refusalReason(for: move) == "moving events needs calendar.events",
                "a read grant never moves a meeting")
    }

    @Test func anyOtherPatchIsRefused() {
        let calendar = guardFor()
        var withTitle = times
        withTitle["summary"] = "x"
        var withAttendees = times
        withAttendees["attendees"] = [["email": "sam@example.org"]]
        let refused = [
            patch(Self.event + "?sendUpdates=all", [:]),
            patch(Self.event + "?sendUpdates=all", ["start": ["dateTime": "2026-10-13T15:00:00-07:00"]]),
            patch(Self.event + "?sendUpdates=all", withTitle),
            patch(Self.event + "?sendUpdates=all", withAttendees),
            patch(Self.event + "?sendUpdates=all", ["start": "x", "end": "y"]),
            patch(Self.event, times),
            patch(Self.event + "?sendUpdates=everyone", times),
            patch(Self.event + "?sendUpdates=all&sendUpdates=none", times),
            patch("https://www.googleapis.com/calendar/v3/calendars/other@example.org/events/ev1?sendUpdates=all", times),
            patch("https://www.googleapis.com/calendar/v3/calendars/robin@example.com/events?sendUpdates=all", times),
            HTTPRequest(method: "PUT", url: URL(string: Self.event + "?sendUpdates=all")!, headers: [:],
                        body: try! JSONSerialization.data(withJSONObject: times)),
        ]
        for request in refused {
            #expect(calendar.refusalReason(for: request) != nil, "\(request.method) \(request.url.absoluteString)")
        }
    }

    @Test func theClientSendsOnlyTheNewTimesAndItsUndoSendsTheOldOnes() async throws {
        let http = FakeHTTPTransport()
        http.on("PATCH", "/calendar/v3/calendars/robin@example.com/events/ev1") { _ in
            jsonResponse(200, ["id": "ev1", "status": "confirmed", "summary": "Planning",
                               "start": ["dateTime": "2026-10-13T15:00:00-07:00"],
                               "end": ["dateTime": "2026-10-13T15:30:00-07:00"], "organizer": ["self": true]])
        }
        let client = GoogleCalendarClient(calendarID: Self.me,
                                          grantedScopes: CalendarScopes.request.write,
                                          tokens: StaticTokenProvider(token: "synthetic-cal-access"), transport: http,
                                          clock: InstantClock(), timeZone: zone)
        let moved = try await client.moveEvent(id: "ev1", start: at(13, 15), end: at(13, 15, 30),
                                               timeZone: zone.identifier, sendUpdates: .all)
        #expect(moved?.start == at(13, 15))
        #expect(moved?.organizerIsSelf == true)
        _ = try await client.moveEvent(id: "ev1", start: at(13, 13), end: at(13, 13, 30), timeZone: zone.identifier,
                                       sendUpdates: .all)
        #expect(http.requests.count == 2)
        for request in http.requests {
            let object = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
            #expect(Set(object.keys) == ["start", "end"], "only the times change")
            #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "sendUpdates" }?.value == "all")
        }
        let undo = try #require(try JSONSerialization.jsonObject(with: http.requests[1].body ?? Data()) as? [String: Any])
        #expect((undo["start"] as? [String: Any])?["dateTime"] as? String == "2026-10-13T13:00:00-07:00",
                "the undo puts the old start back")
    }

    @Test func aReadGrantNeverSendsAMove() async {
        let http = FakeHTTPTransport()
        let client = GoogleCalendarClient(calendarID: Self.me,
                                          grantedScopes: CalendarScopes.request.read,
                                          tokens: StaticTokenProvider(token: "synthetic-cal-access"), transport: http,
                                          clock: InstantClock(), timeZone: zone)
        await #expect(throws: GoogleCalendarError.self) {
            _ = try await client.moveEvent(id: "ev1", start: at(13, 15), end: at(13, 15, 30), timeZone: zone.identifier,
                                           sendUpdates: .none)
        }
        #expect(http.requests.isEmpty)
    }
}
