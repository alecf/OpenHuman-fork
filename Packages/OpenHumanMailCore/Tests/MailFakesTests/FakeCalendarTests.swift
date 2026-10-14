import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFakes

private let hour: TimeInterval = 3_600

@Test func eventsOverlappingTheRangeComeBackSoonestFirst() async throws {
    let base = fixedNow
    let calendar = FakeCalendar(events: [
        CalendarEvent(id: "late", title: "Late", start: base.addingTimeInterval(5 * hour), end: base.addingTimeInterval(6 * hour)),
        CalendarEvent(id: "early", title: "Early", start: base.addingTimeInterval(-hour), end: base.addingTimeInterval(hour)),
        CalendarEvent(id: "ends-at-from", title: "Before", start: base.addingTimeInterval(-2 * hour), end: base),
        CalendarEvent(id: "starts-at-to", title: "After", start: base.addingTimeInterval(8 * hour),
                      end: base.addingTimeInterval(9 * hour)),
    ])
    let events = try await calendar.events(from: base, to: base.addingTimeInterval(8 * hour))
    #expect(events.map(\.id) == ["early", "late"])
    #expect(calendar.calls == [.events(from: base, to: base.addingTimeInterval(8 * hour))])
}

@Test func freeBusyMergesOverlapsClipsToTheRangeAndSkipsAllDayEvents() async throws {
    let base = fixedNow
    let calendar = FakeCalendar(events: [
        CalendarEvent(id: "a", title: "A", start: base.addingTimeInterval(-hour), end: base.addingTimeInterval(hour)),
        CalendarEvent(id: "b", title: "B", start: base.addingTimeInterval(0.5 * hour), end: base.addingTimeInterval(2 * hour)),
        CalendarEvent(id: "c", title: "C", start: base.addingTimeInterval(3 * hour), end: base.addingTimeInterval(4 * hour)),
        CalendarEvent(id: "d", title: "Offsite", start: base, end: base.addingTimeInterval(24 * hour), isAllDay: true),
    ])
    calendar.freeBusyErrors = ["notFound"]
    let answer = try await calendar.freeBusy(from: base, to: base.addingTimeInterval(10 * hour))
    #expect(answer.busy == [CalendarBusyInterval(start: base, end: base.addingTimeInterval(2 * hour)),
                            CalendarBusyInterval(start: base.addingTimeInterval(3 * hour), end: base.addingTimeInterval(4 * hour))])
    #expect(answer.errors == ["notFound"])
}

@Test func createRecordsTheDraftAndTheEventShowsUpInLaterReads() async throws {
    let calendar = FakeCalendar()
    let draft = CalendarEventDraft(title: "Lunch", start: fixedNow, end: fixedNow.addingTimeInterval(hour),
                                   timeZone: "Europe/London", attendees: [EmailAddress(email: "sam@example.com")])
    let event = try await calendar.createEvent(draft)
    #expect(event.title == "Lunch" && event.timeZone == "Europe/London" && event.attendees.count == 1)
    #expect(calendar.created == [event] && calendar.createCalls == 1)
    #expect(try await calendar.events(from: fixedNow, to: fixedNow.addingTimeInterval(hour)) == [event])
}

@Test func aFailingCalendarThrowsAndStillRecordsTheCall() async throws {
    let calendar = FakeCalendar.sample(now: fixedNow, timeZone: try #require(TimeZone(identifier: "UTC")))
    calendar.failure = "offline"
    await #expect(throws: CalendarError.failed("offline")) {
        try await calendar.events(from: fixedNow, to: fixedNow.addingTimeInterval(hour))
    }
    await #expect(throws: CalendarError.failed("offline")) {
        try await calendar.createEvent(CalendarEventDraft(title: "x", start: fixedNow, end: fixedNow.addingTimeInterval(hour),
                                                          timeZone: "UTC"))
    }
    #expect(calendar.createCalls == 1 && calendar.created.isEmpty)
}

@Test func theSampleWeekIsDeterministicAndInTheGivenZone() throws {
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let a = FakeCalendar.sample(now: fixedNow, timeZone: zone).allEvents
    let b = FakeCalendar.sample(now: fixedNow, timeZone: zone).allEvents
    #expect(a == b && a.count >= 14)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let first = try #require(a.first { $0.id == "sample-0-a" })
    #expect(calendar.component(.hour, from: first.start) == 9 && calendar.component(.minute, from: first.start) == 30)
    #expect(calendar.isDate(first.start, inSameDayAs: fixedNow))
    #expect(a.contains { $0.isAllDay })
    #expect(FakeCalendar.sample(now: fixedNow, timeZone: zone).info.isSample)
}

@Test func theSampleWeekCoversTheFullEditChecks() throws {
    let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let sample = FakeCalendar.sample(now: fixedNow, timeZone: zone)
    let events = sample.allEvents
    #expect(sample.abilities.contains(.editFull))
    #expect(events.contains { $0.organizerIsMe == false && $0.canRespond && !$0.attendees.isEmpty }, "someone else's invitation")
    let series = events.filter { $0.isRecurring && $0.organizerIsMe == true }
    #expect(series.count >= 2 && series.contains { !$0.extras.recurrence.isEmpty }, "a series the user organizes")
    #expect(events.contains { ($0.notes ?? "").contains("<a href=") }, "an HTML description")
    #expect(events.contains { ($0.notes ?? "").contains("\\n") }, "an .ics-escaped description")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    #expect(events.contains { !$0.isAllDay && calendar.component(.hour, from: $0.start) >= 18 }, "an evening event")
}

@Test func draftProblemsAreInWords() {
    let ok = CalendarEventDraft(title: "Sync", start: fixedNow, end: fixedNow.addingTimeInterval(hour), timeZone: "UTC")
    #expect(ok.problem == nil)
    var bad = ok
    bad.title = "  "
    #expect(bad.problem == "Add a title.")
    bad = ok
    bad.end = ok.start
    #expect(bad.problem == "The event must end after it starts.")
    bad = ok
    bad.timeZone = "Mars/Olympus"
    #expect(bad.problem == "Unknown time zone.")
    #expect(ok.sendUpdates == .none, "inviting by email is an explicit choice")
    #expect(CalendarSendUpdates.allCases.map(\.rawValue) == ["all", "externalOnly", "none"])
}

@Test func deleteRemovesTheEventAndAMeetDraftGetsALinkOnTheExampleDomain() async throws {
    let calendar = FakeCalendar()
    var draft = CalendarEventDraft(title: "Sync", start: fixedNow, end: fixedNow.addingTimeInterval(hour), timeZone: "UTC")
    #expect(!draft.addMeetLink, "a draft made in code adds no link unless asked")
    draft.addMeetLink = true
    let event = try await calendar.createEvent(draft)
    #expect(event.meetLink?.host == "meet.example", "never a real meeting address")
    try await calendar.deleteEvent(event)
    #expect(calendar.deleted == [event.id] && calendar.deleteCalls == 1 && calendar.allEvents.isEmpty)
    #expect(calendar.calls.last == .delete(id: event.id))
    #expect(calendar.readCalls == 0)
}

@Test func onlyADraftWithAttendeesAndInvitationsEmailsAnyone() {
    let sam = EmailAddress(email: "sam@example.com")
    let base = CalendarEventDraft(title: "x", start: fixedNow, end: fixedNow.addingTimeInterval(hour), timeZone: "UTC")
    var draft = base
    draft.sendUpdates = .all
    #expect(!draft.emailsAttendees, "nobody to email")
    draft.attendees = [sam]
    #expect(draft.emailsAttendees)
    draft.sendUpdates = .externalOnly
    #expect(draft.emailsAttendees)
    draft.sendUpdates = .none
    #expect(!draft.emailsAttendees)
    #expect(draft.mayEmailAttendees, "review G2: Google may still email attendees with none")
    #expect(!base.mayEmailAttendees)
}

@Test func anUnclearCreateKeepsTheEventOnlyWhenAsked() async throws {
    let calendar = FakeCalendar()
    let draft = CalendarEventDraft(title: "x", start: fixedNow, end: fixedNow.addingTimeInterval(hour), timeZone: "UTC")
    calendar.createOutcome = .unclear(created: false)
    await #expect(throws: CalendarError.self) { _ = try await calendar.createEvent(draft) }
    #expect(calendar.allEvents.isEmpty && calendar.created.isEmpty)
    calendar.createOutcome = .unclear(created: true)
    await #expect(throws: CalendarError.self) { _ = try await calendar.createEvent(draft) }
    #expect(calendar.allEvents.count == 1 && calendar.created.isEmpty && calendar.createCalls == 2)
}

@Test func theFakeConnectionRecordsItsCallsAndPublishesItsState() async throws {
    let connection = FakeCalendarConnection(account: "robin@example.com")
    var states = connection.connectionStates().makeAsyncIterator()
    #expect(await states.next()?.status == .disconnected)
    try await connection.connect()
    let connected = await states.next()
    #expect(connected?.status == .connected && connected?.canCreateEvents == true)
    #expect(connected?.needsRestart == true, "the module registers at the next launch")
    try await connection.disconnect()
    #expect(await states.next()?.needsRestart == false)
    connection.failure = "no"
    await #expect(throws: CalendarError.failed("no")) { try await connection.connect() }
    #expect(connection.connectCalls == 2 && connection.disconnectCalls == 1)
}
