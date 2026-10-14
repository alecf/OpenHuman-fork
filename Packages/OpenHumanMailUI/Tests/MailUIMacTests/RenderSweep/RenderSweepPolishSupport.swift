import AppKit
import Foundation
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

enum SweepClock {
    static let now = Date(timeIntervalSince1970: 1_791_799_680)
    static let timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .gmt
    static let locale = Locale(identifier: "en_US_POSIX")
    static var calendar: Calendar { CalendarDateMentions.calendar(timeZone) }

    static func weekday(_ weekday: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let week = CalendarPeriod.containing(now, kind: .week, calendar: calendar)
        let day = week.days.first { calendar.component(.weekday, from: $0) == weekday } ?? week.days[0]
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}

extension SweepTheme {
    var isAccessibilityVariant: Bool { reduceMotion || increaseContrast }
}

struct SweepFixtureError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
enum SweepOverlayFixture {
    static let reminderDue = Date(timeIntervalSince1970: 1_791_968_400)
    static let inlineReply = "Thanks, Thursday at 10 works. I'll send the agenda tonight."

    static func environment(ai: Bool = false) -> AppEnvironment {
        AppEnvironment.fake(corpus: .rich(threadCount: 200, now: SweepClock.now),
                            options: .init(remoteAck: .immediate, now: { SweepClock.now }),
                            featureFlags: FeatureFlags(), ai: ai ? aiCenter() : nil)
    }

    static func aiCenter() -> AICenter {
        AICenter.make(registry: ProviderRegistry(providers: [FakeAIProvider(displayName: "On-device test model")]),
                      settings: AISettingsBox(store: InMemoryAISettingsStore()))
    }

    static func pinClock(_ overlays: OverlayCenter) {
        overlays.timeZone = SweepClock.timeZone
        overlays.locale = SweepClock.locale
        overlays.now = { SweepClock.now }
    }

    static func timePicker(_ overlays: OverlayCenter) throws -> TimePickerModel {
        if case .time(let model) = overlays.overlay { return model }
        throw SweepFixtureError(description: "no time picker is shown")
    }

    static func zeroCard(_ overlays: OverlayCenter) throws -> GetMeToZeroModel {
        if case .zero(let model) = overlays.overlay { return model }
        throw SweepFixtureError(description: "the Get me to zero card is not shown")
    }

    static func dismissToasts(_ environment: AppEnvironment) {
        let notices = environment.notices
        for toast in notices.toasts { notices.dismiss(toast.id) }
    }
}

@MainActor
enum EventCardSweep {
    static let longID = "vendor-review"
    static let acceptedID = "vendor-review-accepted"
    static let title = "Vendor onboarding review"
    static let location = "Juniper room, 4th floor, 200 Example Avenue"
    static let meetLink = URL(string: "https://meet.example.org/vnd-rvw-001")
    static let attendees = [
        EmailAddress(name: "Sam Rivera", email: "sam@example.org"),
        EmailAddress(name: "Priya Natarajan", email: "priya@example.net"),
        EmailAddress(name: "Theo Grant", email: "theo@example.com"),
        EmailAddress(name: "Ops Desk", email: "ops@example.org"),
        EmailAddress(name: "Lena Park", email: "lena@example.net"),
        FakeCorpus.me,
    ]
    static let notes = """
        Goal: agree how a new vendor moves from a signed contract to its first delivery, and who owns each step on \
        the way.

        1. Intake: where requests arrive today, what we ask vendors for up front, and which of the old forms we can \
        retire this quarter.
        2. Security review: the questionnaire, its usual turnaround, and how to run it alongside the legal review \
        instead of after it.
        3. Access: who creates accounts, how long they last, and the checklist for removing them when a contract ends.
        4. First delivery: a shared timeline template, the kickoff call, and the moment the vendor is handed to the \
        team that works with them.

        Pre-read: https://docs.example.org/vendor-onboarding-plan

        Please add open questions to the plan by Tuesday so we can spend the hour on decisions, not updates. If you \
        cannot join, leave a short note on points 2 and 3.
        """

    static var now: Date { SweepClock.weekday(4, 11) }

    static func event(id: String, weekday: Int, response: CalendarResponse) -> CalendarEvent {
        CalendarEvent(id: id, title: title, start: SweepClock.weekday(weekday, 14), end: SweepClock.weekday(weekday, 15),
                      attendees: attendees, meetLink: meetLink, organizerIsMe: false, location: location, notes: notes,
                      myResponse: response)
    }

    static func environment() -> AppEnvironment {
        let corpus = FakeCorpus.rich(threadCount: 200, now: SweepClock.now)
        let work = corpus.accounts[0].email
        let calendar = FakeCalendar(events: [event(id: longID, weekday: 4, response: .needsAction),
                                             event(id: acceptedID, weekday: 5, response: .accepted)],
                                    info: CalendarProviderInfo(name: "Google Calendar", account: work))
        let connections = FakeCalendarConnections(providers: [work: calendar])
        return AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate, now: { SweepClock.now }),
                                   featureFlags: FeatureFlags(), calendar: calendar, calendarConnections: connections)
    }
}

@MainActor
@Suite struct RenderSweepPolishFixtureTests {
    @Test func theSweepClockIsMondayTwelfthOfOctober2026At1008UTC() {
        let parts = SweepClock.calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: SweepClock.now)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 12)
        #expect(parts.hour == 10 && parts.minute == 8)
        #expect(parts.weekday == 2, "a Monday")
        let due = SweepClock.calendar.dateComponents([.month, .day, .hour, .weekday], from: SweepOverlayFixture.reminderDue)
        #expect(due.month == 10 && due.day == 14 && due.hour == 9 && due.weekday == 4, "Wednesday 09:00")
    }

    @Test func theEventCardDaysAreWednesdayAndThursdayOfTheSweepWeek() {
        let wednesday = SweepClock.calendar.dateComponents([.month, .day, .hour], from: SweepClock.weekday(4, 14))
        #expect(wednesday.month == 10 && wednesday.day == 14 && wednesday.hour == 14)
        let thursday = SweepClock.calendar.dateComponents([.month, .day], from: SweepClock.weekday(5, 14))
        #expect(thursday.month == 10 && thursday.day == 15)
        #expect((800...1_000).contains(EventCardSweep.notes.count), "about 900 characters of notes")
    }

    @Test func themeSelectionKeepsEveryThemeWhenUnsetOrBlank() {
        let all = SweepTheme.allBuiltIns + SweepTheme.allAccessibility
        #expect(SweepTheme.selected(all, slugs: nil).map(\.slug) == all.map(\.slug))
        #expect(SweepTheme.selected(all, slugs: " , ").map(\.slug) == all.map(\.slug))
    }

    @Test func themeSelectionKeepsOnlyTheListedSlugsInTheirOwnOrder() {
        let all = SweepTheme.allBuiltIns + SweepTheme.allAccessibility
        #expect(SweepTheme.selected(all, slugs: "dark, Light").map(\.slug) == ["light", "dark"])
        #expect(SweepTheme.selected(all, slugs: "light-increase-contrast").map(\.slug) == ["light-increase-contrast"])
        #expect(SweepTheme.selected(all, slugs: "sepia").isEmpty, "an unknown slug selects nothing (the script refuses it)")
    }
}
