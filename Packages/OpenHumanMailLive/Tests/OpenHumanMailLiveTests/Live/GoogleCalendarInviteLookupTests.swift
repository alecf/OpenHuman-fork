import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanMailLive

private let calendarPath = "/calendar/v3/calendars/robin@example.com/events"
private let start = ISO8601DateFormatter().date(from: "2026-10-21T17:00:00Z")!
private let query = CalendarInviteQuery(uid: "weekly-1@example.com", title: "Weekly sync", start: start,
                                        end: start.addingTimeInterval(1_800), organizer: "dana@example.com")

private func provider(_ grant: [String], _ http: FakeHTTPTransport) -> GoogleCalendarProvider {
    let client = GoogleCalendarClient(calendarID: "robin@example.com", grantedScopes: grant,
                                      tokens: StaticTokenProvider(token: "synthetic-cal-access"), transport: http,
                                      clock: InstantClock(), timeZone: TimeZone(identifier: "UTC")!)
    return GoogleCalendarProvider(client: client, account: "robin@example.com", createRefusal: nil)
}

@Sendable private func item(_ id: String, uid: String?, title: String = "Weekly sync", at time: String = "2026-10-21T17:00:00Z",
                            organizer: String? = "dana@example.com", series: String? = nil) -> [String: Any] {
    var event: [String: Any] = ["id": id, "summary": title, "start": ["dateTime": time],
                                "end": ["dateTime": time.replacingOccurrences(of: ":00:00Z", with: ":30:00Z")],
                                "attendees": [["email": "robin@example.com", "self": true, "responseStatus": "needsAction"]]]
    if let uid { event["iCalUID"] = uid }
    if let organizer { event["organizer"] = ["email": organizer] }
    if let series { event["recurringEventId"] = series }
    return event
}

@Sendable private func asksForUID(_ request: HTTPRequest) -> Bool {
    URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "iCalUID" } == true
}

@MainActor
@Suite struct GoogleCalendarInviteLookupTests {
    @Test func aListingThatIgnoresTheFilterStillPicksTheEventByItsUIDWithEitherGrant() async throws {
        for grant in [CalendarScopes.request.read, CalendarScopes.request.write] {
            let http = FakeHTTPTransport()
            http.on("GET", calendarPath) { _ in
                FakeHTTPTransport.json(200, ["items": [
                    item("lunch", uid: "lunch@example.com", title: "Weekly sync"),
                    item("series1_20261021T170000Z", uid: "weekly-1@example.com", series: "series1"),
                ]])
            }
            let found = try await provider(grant, http).invitedEvent(query, wholeSeries: false)
            #expect(found?.id == "series1_20261021T170000Z" && found?.recurringEventID == "series1", "\(grant)")
            #expect(http.requests.count == 1 && http.requests.allSatisfy { $0.method == "GET" }, "\(grant): one read")
        }
    }

    @Test func withoutTheUIDTheWindowIsReadAgainAndTitleStartAndOrganizerDecide() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", calendarPath) { request in
            asksForUID(request) ? FakeHTTPTransport.json(200, ["items": [[String: Any]]()])
                : FakeHTTPTransport.json(200, ["items": [
                    item("not-dana", uid: nil, organizer: "lee@example.org"),
                    item("later", uid: nil, at: "2026-10-21T18:00:00Z"),
                    item("copy", uid: nil),
                ]])
        }
        let found = try await provider(CalendarScopes.request.write, http).invitedEvent(query, wholeSeries: false)
        #expect(found?.id == "copy", "same title, start and organizer; never the other organizer's or a later event")
        #expect(http.requests.count == 2 && asksForUID(http.requests[0]) && !asksForUID(http.requests[1]))
    }

    @Test func twoCandidatesRefuseAndNoneIsNil() async throws {
        let twice = FakeHTTPTransport()
        twice.on("GET", calendarPath) { _ in
            FakeHTTPTransport.json(200, ["items": [item("copy1", uid: nil), item("copy2", uid: nil, organizer: nil)]])
        }
        await #expect(throws: CalendarError.self) { _ = try await provider(CalendarScopes.request.write, twice).invitedEvent(query, wholeSeries: false) }

        let empty = FakeHTTPTransport()
        empty.on("GET", calendarPath) { _ in FakeHTTPTransport.json(200, ["items": [[String: Any]]()]) }
        #expect(try await provider(CalendarScopes.request.write, empty).invitedEvent(query, wholeSeries: false) == nil)
        #expect(empty.requests.count == 2, "the UID read, then the window read")
    }

    @Test func theWholeSeriesIsNamedByTheOccurrencesSeries() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", calendarPath) { _ in
            FakeHTTPTransport.json(200, ["items": [item("series1_20261021T170000Z", uid: "weekly-1@example.com",
                                                        series: "series1")]])
        }
        let found = try await provider(CalendarScopes.request.write, http).invitedEvent(query, wholeSeries: true)
        #expect(found?.id == "series1" && found?.recurringEventID == nil, "the answer reads the series' own event by id")
        #expect(found?.canRespond == true)
    }
}
