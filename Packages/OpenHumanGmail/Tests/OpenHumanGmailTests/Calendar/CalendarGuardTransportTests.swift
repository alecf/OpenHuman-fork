import Foundation
import OpenHumanCore
import Synchronization
import Testing
@testable import OpenHumanGmail

@Suite struct CalendarGuardTransportTests {
    private static let me = "robin@example.com"
    private static let base = "https://www.googleapis.com/calendar/v3"
    private static let events = base + "/calendars/robin@example.com/events"

    private func request(_ method: String, _ url: String, body: Data? = nil,
                         headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: method, url: URL(string: url)!, headers: headers, body: body)
    }

    private func guardFor(_ mode: SafeMode, scopes: [String]? = nil, wire: ScriptedTransport = ScriptedTransport(),
                          clock: any OHClock = SystemClock()) -> CalendarGuardTransport {
        CalendarGuardTransport(wrapping: wire, calendarID: Self.me, mode: mode,
                               grantedScopes: scopes ?? CalendarScopes.requested(for: mode), clock: clock)
    }

    private func numberingWire() -> ScriptedTransport {
        let next = Mutex(0)
        return ScriptedTransport { request in
            guard request.method == "POST" else { return HTTPResponse(status: 204, headers: [:], body: Data()) }
            let id = next.withLock { n -> String in
                n += 1
                return "ev\(n)"
            }
            return jsonResponse(200, ["id": id, "status": "confirmed"])
        }
    }

    private func insertBody(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func readsPassInEveryMode() {
        for mode in SafeMode.allCases {
            let calendar = guardFor(mode)
            #expect(calendar.refusalReason(for: request("GET", Self.events + "?timeMin=x&singleEvents=true")) == nil, "\(mode)")
            #expect(calendar.refusalReason(for: request("POST", Self.base + "/freeBusy", body: Data("{}".utf8))) == nil,
                    "freebusy.query is a read sent as a POST")
        }
    }

    @Test func anInsertPassesOnlyInWriteModeWithCalendarEvents() {
        let insert = request("POST", Self.events + "?sendUpdates=none", body: Data("{}".utf8))
        #expect(guardFor(.normal).refusalReason(for: insert) == nil)
        #expect(guardFor(.normal).allowsWrites)
        #expect(guardFor(.readOnly).refusalReason(for: insert) != nil, "read-only")
        #expect(guardFor(.writeAllowlist).refusalReason(for: insert) != nil, "write-allowlist never creates events")
        #expect(guardFor(.readOnly, scopes: CalendarScopes.requested(for: .normal)).refusalReason(for: insert) != nil,
                "a write grant in a read-only run")
        #expect(guardFor(.normal, scopes: CalendarScopes.requested(for: .readOnly)).refusalReason(for: insert) != nil,
                "a read grant in a write run")
        #expect(guardFor(.normal).refusalReason(for: request("POST", Self.base + "/calendars/someone@example.com/events")) != nil,
                "only the account's own calendar")
    }

    @Test func onlyAnEventCreatedHereCanBeDeletedAndOnlyOnce() async throws {
        let wire = ScriptedTransport { request in
            request.method == "POST" ? jsonResponse(200, ["id": "ev1", "status": "confirmed"])
                                     : HTTPResponse(status: 204, headers: [:], body: Data())
        }
        let calendar = guardFor(.normal, wire: wire)
        let delete = request("DELETE", Self.events + "/ev1?sendUpdates=none")
        await #expect(throws: TransportError.blockedBySafeMode("DELETE /calendar/v3/calendars/<redacted>/events/ev1")) {
            _ = try await calendar.send(delete)
        }
        #expect(wire.requests.isEmpty, "refused before the wire")
        _ = try await calendar.send(request("POST", Self.events, body: Data("{}".utf8)))
        #expect(calendar.createdEventIDs == ["ev1"])
        _ = try await calendar.send(delete)
        #expect(wire.requests.map(\.method) == ["POST", "DELETE"])
        #expect(calendar.createdEventIDs.isEmpty)
        await #expect(throws: TransportError.self) { _ = try await calendar.send(delete) }
        #expect(wire.requests.count == 2, "a second delete of the same event is refused")
        #expect(guardFor(.readOnly).refusalReason(for: delete) != nil)
    }

    @Test func anEventCreatedWithAttendeesIsNeverDeleted() async throws {
        let wire = numberingWire()
        let calendar = guardFor(.normal, wire: wire)
        _ = try await calendar.send(request("POST", Self.events + "?sendUpdates=none",
                                            body: insertBody(["summary": "Lunch", "attendees": [["email": "alice@example.com"]]])))
        _ = try await calendar.send(request("POST", Self.events + "?sendUpdates=none", body: Data("not json".utf8)))
        #expect(calendar.createdEventIDs == ["ev1", "ev2"])
        for id in ["ev1", "ev2"] {
            let delete = request("DELETE", Self.events + "/\(id)?sendUpdates=none")
            #expect(calendar.refusalReason(for: delete) != nil, "\(id)")
            await #expect(throws: TransportError.self) { _ = try await calendar.send(delete) }
        }
        #expect(wire.requests.map(\.method) == ["POST", "POST"], "no delete reached the wire")
    }

    @Test func anAttendeeLessEventCanBeDeletedOnlyInsideTheUndoWindow() async throws {
        let wire = numberingWire()
        let clock = TestClock()
        let calendar = guardFor(.normal, wire: wire, clock: clock)
        let body = insertBody(["summary": "Focus", "attendees": [Any]()])
        _ = try await calendar.send(request("POST", Self.events, body: body))
        _ = try await calendar.send(request("POST", Self.events, body: insertBody(["summary": "Focus"])))
        clock.advance(by: .seconds(5))
        _ = try await calendar.send(request("DELETE", Self.events + "/ev1?sendUpdates=none"))
        #expect(wire.requests.last?.method == "DELETE", "inside the window: the undo's delete goes out")
        clock.advance(by: .seconds(55))
        let late = request("DELETE", Self.events + "/ev2?sendUpdates=none")
        #expect(calendar.refusalReason(for: late) != nil)
        await #expect(throws: TransportError.self) { _ = try await calendar.send(late) }
        #expect(wire.requests.filter { $0.method == "DELETE" }.count == 1, "a minute later: refused before the wire")
        #expect(CalendarGuardTransport.deleteWindow < 60)
    }

    @Test func everythingElseIsRefusedBeforeTheWire() async throws {
        let wire = ScriptedTransport()
        let calendar = guardFor(.normal, wire: wire)
        let refused: [HTTPRequest] = [
            request("GET", "https://gmail.googleapis.com/calendar/v3/calendars/robin@example.com/events"),
            request("GET", "http://www.googleapis.com/calendar/v3/calendars/robin@example.com/events"),
            request("GET", "https://www.googleapis.com:8443/calendar/v3/calendars/robin@example.com/events"),
            request("GET", "https://user@www.googleapis.com/calendar/v3/calendars/robin@example.com/events"),
            request("GET", "https://www.googleapis.com/gmail/v1/users/me/labels"),
            request("GET", Self.base + "/calendars/robin@example.com/../events"),
            request("POST", Self.base + "/calendars/robin@example.com/events/%2E%2E", body: Data("{}".utf8)),
            request("POST", Self.base + "/calendars/robin@example.com//events", body: Data("{}".utf8)),
            request("POST", Self.base + "/freeBusy/", body: Data("{}".utf8)),
            request("PUT", Self.events + "/ev1", body: Data("{}".utf8)),
            request("PATCH", Self.events + "/ev1", body: Data("{}".utf8)),
            request("POST", Self.events + "/ev1/move?destination=x"),
            request("POST", Self.events + "/import", body: Data("{}".utf8)),
            request("POST", Self.events + "/quickAdd?text=x"),
            request("POST", Self.events + "/watch", body: Data("{}".utf8)),
            request("POST", Self.base + "/calendars/robin@example.com/clear"),
            request("DELETE", Self.base + "/calendars/robin@example.com"),
            request("POST", Self.base + "/calendars", body: Data("{}".utf8)),
            request("POST", Self.base + "/users/me/calendarList", body: Data("{}".utf8)),
            request("DELETE", Self.base + "/users/me/calendarList/robin@example.com"),
            request("POST", Self.base + "/calendars/robin@example.com/acl", body: Data("{}".utf8)),
            request("PUT", Self.base + "/users/me/settings/timezone", body: Data("{}".utf8)),
            request("POST", Self.base + "/freeBusy", body: Data("{}".utf8), headers: ["X-HTTP-Method-Override": "DELETE"]),
            request("GET", Self.events + "?$httpMethod=DELETE"),
            request("GET", Self.events, body: Data("{}".utf8)),
            request("get", Self.events),
        ]
        for request in refused {
            #expect(calendar.refusalReason(for: request) != nil, "\(request.method) \(request.url.absoluteString)")
            await #expect(throws: TransportError.self) { _ = try await calendar.send(request) }
        }
        #expect(wire.requests.isEmpty, "nothing refused reached the wire")
    }

    @Test func theRefusalNamesNoAddress() async throws {
        let calendar = guardFor(.readOnly)
        do {
            _ = try await calendar.send(request("POST", Self.events, body: Data("{}".utf8)))
            Issue.record("an insert passed in read-only")
        } catch TransportError.blockedBySafeMode(let summary) {
            #expect(summary == "POST /calendar/v3/calendars/<redacted>/events")
            #expect(!summary.contains("@") && !summary.contains("example"))
        }
    }
}
