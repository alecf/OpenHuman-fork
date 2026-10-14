import Foundation
import Testing
@testable import MailFeatures

private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, in tz: TimeZone) -> Date {
    CalendarDateMentions.calendar(tz).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

@Suite struct CalendarDateMentionsTests {
    @Test func aDateWithATimeIsTheWallClockTimeInTheSidebarsZone() throws {
        let text = "Can we meet on Wednesday, October 14, 2026 at 3:00 PM? Otherwise Thursday works."
        for id in ["America/New_York", "Asia/Tokyo", "Europe/London"] {
            let mention = try #require(CalendarDateMentions.find(in: text, timeZone: zone(id)).first)
            #expect(mention.date == date(2026, 10, 14, 15, in: zone(id)), "\(id)")
            #expect(mention.hasTime && !mention.namedTimeZone && mention.duration == nil)
        }
    }

    @Test func aNamedZoneKeepsItsInstant() throws {
        let text = "Call at 3pm PST on October 20, 2026"
        let la = date(2026, 10, 20, 15, in: zone("America/Los_Angeles"))
        for id in ["America/New_York", "Europe/Berlin"] {
            let mention = try #require(CalendarDateMentions.find(in: text, timeZone: zone(id)).first)
            #expect(mention.namedTimeZone && mention.date == la, "\(id)")
        }
    }

    @Test func aBareDateHasNoTimeAndASpanKeepsItsDuration() throws {
        let tz = zone("Europe/Paris")
        let bare = try #require(CalendarDateMentions.find(in: "See you on 2026-10-22", timeZone: tz).first)
        #expect(!bare.hasTime)
        #expect(CalendarDateMentions.calendar(tz).startOfDay(for: bare.date) == date(2026, 10, 22, in: tz))
        let span = try #require(CalendarDateMentions.find(in: "Meeting from 2pm to 4pm on 10/21/2026", timeZone: tz).first)
        #expect(span.hasTime && span.duration == 2 * 3_600)
        #expect(span.date == date(2026, 10, 21, 14, in: tz))
    }

    @Test func severalDatesComeBackInTextOrderAndPlainNumbersAreNotDates() {
        let tz = zone("UTC")
        let text = "How about October 14, 2026 at 10am or October 15, 2026 at 2pm? I have 12 apples and 3 oranges."
        let found = CalendarDateMentions.find(in: text, timeZone: tz)
        #expect(found.map(\.date) == [date(2026, 10, 14, 10, in: tz), date(2026, 10, 15, 14, in: tz)])
        #expect(CalendarDateMentions.find(in: "I have 12 apples and 3 oranges.", timeZone: tz).isEmpty)
        #expect(CalendarDateMentions.find(in: "", timeZone: tz).isEmpty)
    }

    @Test func daysAreDistinctAscendingUpcomingFirstAndCapped() {
        let tz = zone("America/New_York")
        let today = date(2026, 10, 10, 9, in: tz)
        let mentions = [
            CalendarDateMention(date: date(2026, 10, 14, 15, in: tz), hasTime: true),
            CalendarDateMention(date: date(2026, 10, 14, 9, in: tz), hasTime: true),
            CalendarDateMention(date: date(2026, 10, 12, 12, in: tz), hasTime: false),
            CalendarDateMention(date: date(2026, 10, 1, 12, in: tz), hasTime: false),
        ] + (20...25).map { CalendarDateMention(date: date(2026, 10, $0, 12, in: tz), hasTime: false) }
        let days = CalendarDateMentions.days(mentions, timeZone: tz, today: today)
        #expect(days.count == CalendarDateMentions.maxDays)
        #expect(days == [12, 14, 20, 21, 22].map { date(2026, 10, $0, in: tz) }, "upcoming days win over the past one")
        let few = CalendarDateMentions.days(Array(mentions.prefix(4)), timeZone: tz, today: today)
        #expect(few == [1, 12, 14].map { date(2026, 10, $0, in: tz) }, "with room, the past day is shown too")
    }

    @Test(arguments: [("3pm", true), ("3 p.m.", true), ("at 15:30", true), ("noon", true), ("Oct 14", false),
                      ("next Tuesday", false), ("2026-10-22", false), ("10/21/2026", false)])
    func timeOfDayComesFromTheWords(_ words: String, _ expected: Bool) {
        #expect(CalendarDateMentions.mentionsTime(words) == expected, "\(words)")
    }
}
