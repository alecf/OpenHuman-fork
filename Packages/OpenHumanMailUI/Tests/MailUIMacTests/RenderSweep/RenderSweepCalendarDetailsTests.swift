import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
enum SidebarDetailsSweep {
    static let theirsID = "sweep-vendor-review"
    static let ownID = "sweep-design-sync"
    static let offsiteID = "sweep-offsite"

    static var now: Date { SweepClock.weekday(4, 9) }

    static func environment() -> AppEnvironment {
        let corpus = FakeCorpus.rich(threadCount: 200, now: SweepClock.now)
        let owner = corpus.accounts[0].email
        let sam = CalendarGuest(email: "sam@example.test", name: "Sam Rivera", response: .accepted)
        var theirs = CalendarEventExtras()
        theirs.guests = [
            CalendarGuest(email: "priya@example.test", name: "Priya Natarajan", response: .accepted),
            sam,
            CalendarGuest(email: "theo@example.test", name: "Theo Grant", response: .declined),
            CalendarGuest(email: "ops@example.test", name: "Ops Desk", isOptional: true, response: .needsAction),
            CalendarGuest(email: "lena@example.test", name: "Lena Park", response: .tentative),
            CalendarGuest(email: owner, name: "Robin Example", response: .needsAction),
        ]
        var own = CalendarEventExtras()
        own.guests = [sam]
        own.recurrence = ["RRULE:FREQ=WEEKLY"]
        let events = [
            CalendarEvent(id: theirsID, title: EventCardSweep.title, start: SweepClock.weekday(4, 14),
                          end: SweepClock.weekday(4, 15), timeZone: "America/Los_Angeles",
                          attendees: theirs.guests.map(\.address), meetLink: EventCardSweep.meetLink, organizerIsMe: false,
                          location: EventCardSweep.location, notes: EventCardSweep.notes, myResponse: .needsAction,
                          extras: theirs),
            CalendarEvent(id: ownID, title: "Design sync", start: SweepClock.weekday(4, 10),
                          end: SweepClock.weekday(4, 10, 30), attendees: [sam.address],
                          meetLink: URL(string: "https://meet.example.test/dsn-sync-001"), organizerIsMe: true,
                          recurringEventID: "design-sync", extras: own),
            CalendarEvent(id: offsiteID, title: "Team offsite planning", start: SweepClock.weekday(4, 0),
                          end: SweepClock.weekday(5, 0), isAllDay: true, timeZone: SweepClock.timeZone.identifier),
        ]
        let calendar = FakeCalendar(events: events, info: CalendarProviderInfo(name: "Google Calendar", account: owner))
        return AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate, now: { SweepClock.now }),
                                   featureFlags: FeatureFlags(), calendar: calendar)
    }
}

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func calendarSidebarEventDetails(_ theme: SweepTheme) async throws {
        let environment = SidebarDetailsSweep.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let sidebar = try #require(environment.calendarSidebar)
        sidebar.timeZone = SweepClock.timeZone
        sidebar.now = { SidebarDetailsSweep.now }
        sidebar.setVisible(true)
        await sidebar.show(thread: nil)
        try await until { sidebar.state == .loaded && sidebar.focusableEvents.count == 3 }
        try await sweepShoot(w.window, screen: "calendar-sidebar-day", theme: theme)
        for (id, screen) in [(SidebarDetailsSweep.theirsID, "calendar-sidebar-event-details"),
                             (SidebarDetailsSweep.ownID, "calendar-sidebar-event-details-own"),
                             (SidebarDetailsSweep.offsiteID, "calendar-sidebar-event-details-all-day")] {
            let event = try #require(sidebar.focusableEvents.first { $0.id == id })
            sidebar.openEvent(event)
            try await sweepShoot(w.window, screen: screen, theme: theme)
        }
        sidebar.closeEvent(keepsFocus: true)
        try await sweepShoot(w.window, screen: "calendar-sidebar-event-focused", theme: theme)
        sidebar.closeEvent()
        sidebar.setVisible(false)
    }
}
