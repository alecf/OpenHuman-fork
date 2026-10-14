import Foundation
import Testing
import OpenHumanCore

@Suite struct WhenParserTests {
    static let tz = TimeZone(identifier: "America/Los_Angeles")!
    static let now = Date(timeIntervalSince1970: 1_791_669_600)
    let parser = WhenParser(timeZone: tz)

    func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Self.tz
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func fixedNowIsSaturdayAfternoon() {
        #expect(local(2026, 10, 10, 15) == Self.now)
    }

    @Test func table() throws {
        let cases: [(String, Date)] = [
            ("now", Self.now),
            ("+2h", Self.now.addingTimeInterval(7200)),
            ("+30m", Self.now.addingTimeInterval(1800)),
            ("in 90 min", Self.now.addingTimeInterval(5400)),
            ("in 2 hours", Self.now.addingTimeInterval(7200)),
            ("+3d", local(2026, 10, 13, 15)),
            ("+1w", local(2026, 10, 17, 15)),
            ("tomorrow", local(2026, 10, 11, 8)),
            ("tomorrow 8am", local(2026, 10, 11, 8)),
            ("Tomorrow at 8:30 PM", local(2026, 10, 11, 20, 30)),
            ("tomorrow 18:00", local(2026, 10, 11, 18)),
            ("tomorrow noon", local(2026, 10, 11, 12)),
            ("tomorrow evening", local(2026, 10, 11, 18)),
            ("today", local(2026, 10, 10, 18)),
            ("tonight", local(2026, 10, 10, 20)),
            ("monday", local(2026, 10, 12, 8)),
            ("mon 9am", local(2026, 10, 12, 9)),
            ("next friday", local(2026, 10, 16, 8)),
            ("saturday", local(2026, 10, 17, 8)),
            ("next week", local(2026, 10, 12, 8)),
            ("this weekend", local(2026, 10, 17, 8)),
            ("5pm", local(2026, 10, 10, 17)),
            ("at 9am", local(2026, 10, 11, 9)),
            ("2026-10-12", local(2026, 10, 12, 8)),
            ("2026-10-12 09:30", local(2026, 10, 12, 9, 30)),
            ("2026-10-12T09:30", local(2026, 10, 12, 9, 30)),
            ("2026-10-12T09:00:00Z", Date(timeIntervalSince1970: 1_791_795_600)),
            ("2026-10-12T11:00:00+02:00", Date(timeIntervalSince1970: 1_791_795_600)),
            ("fri 3pm", local(2026, 10, 16, 15)),
            ("in 2 days", local(2026, 10, 12, 15)),
            ("next tue", local(2026, 10, 13, 8)),
            ("dec 1", local(2026, 12, 1, 8)),
            ("tomorrow 7", local(2026, 10, 11, 7)),
            ("December 1st", local(2026, 12, 1, 8)),
            ("1 dec", local(2026, 12, 1, 8)),
            ("dec 1 9am", local(2026, 12, 1, 9)),
            ("dec 1 at 17:30", local(2026, 12, 1, 17, 30)),
            ("dec 1 2027", local(2027, 12, 1, 8)),
            ("sept 3", local(2027, 9, 3, 8)),
            ("oct 10", local(2026, 10, 10, 8)),
            ("feb 29", local(2028, 2, 29, 8)),
            ("tomorrow 3", local(2026, 10, 11, 15)),
            ("tomorrow 12", local(2026, 10, 11, 12)),
            ("tomorrow 19", local(2026, 10, 11, 19)),
            ("mon 11", local(2026, 10, 12, 11)),
            ("dec 1 9", local(2026, 12, 1, 9)),
        ]
        for (input, expected) in cases {
            let got = try parser.parse(input, now: Self.now)
            #expect(got == expected, "\(input)")
        }
    }

    @Test(arguments: ["", "  ", "soonish", "tomorrow 25:00", "13pm", "8", "2026-13-01", "2026-02-30",
                      "+5 parsecs", "monday blah", "12/1", "1.12.", "feb 30", "dec 32", "tomorrow 24", "dec",
                      "feb 29 2027", "7 tomorrow"])
    func rejects(input: String) {
        #expect(throws: WhenParserError.self) { try parser.parse(input, now: Self.now) }
    }

    @Test func timeZoneMatters() throws {
        let utc = WhenParser(timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(try utc.parse("tomorrow 8am", now: Self.now) == Date(timeIntervalSince1970: 1_791_705_600))
    }
}

@Suite struct WhenParserLaterTodayTests {
    static let tz = TimeZone(identifier: "America/Los_Angeles")!
    let parser = WhenParser(timeZone: tz)

    func local(_ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Self.tz
        return c.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: mi))!
    }

    @Test func laterTodayAcrossTheDay() throws {
        let cases: [(now: Date, expected: Date, why: String)] = [
            (local(13, 7), local(13, 10), "07:00 + 3 h"),
            (local(13, 8), local(13, 11), "08:00 + 3 h"),
            (local(13, 8, 20), local(13, 12), "08:20 + 3 h rounds up"),
            (local(13, 17, 30), local(13, 21), "17:30 + 3 h rounds up"),
            (local(13, 18, 30), local(13, 20), "after 18:00 it is this evening"),
            (local(13, 21), local(14, 8), "nothing left today: tomorrow morning"),
            (local(13, 23, 30), local(14, 8), "late night: tomorrow morning"),
        ]
        for phrase in ["later today", "later", "Later  Today", "later on"] {
            for c in cases { #expect(try parser.parse(phrase, now: c.now) == c.expected, "\(phrase): \(c.why)") }
        }
    }

    @Test func tonightAndThisEvening() throws {
        #expect(try parser.parse("tonight", now: local(13, 8)) == local(13, 20))
        #expect(try parser.parse("this evening", now: local(13, 15)) == local(13, 20))
        #expect(try parser.parse("tonight", now: local(13, 21)) == local(13, 22), "next whole hour")
        #expect(try parser.parse("tonight", now: local(13, 22, 30)) == local(14, 8), "too late: tomorrow morning")
        #expect(try parser.parse("tonight 9pm", now: local(13, 8)) == local(13, 21), "day word still takes a time")
    }

    @Test func thisAfternoon() throws {
        #expect(try parser.parse("this afternoon", now: local(13, 8)) == local(13, 13))
        #expect(try parser.parse("this afternoon", now: local(13, 14, 10)) == local(13, 16))
        #expect(try parser.parse("this afternoon", now: local(13, 18, 30)) == local(13, 20))
    }

    @Test func smallRelativeWords() throws {
        let now = local(13, 8, 15)
        #expect(try parser.parse("in an hour", now: now) == local(13, 9, 15))
        #expect(try parser.parse("in a minute", now: now) == local(13, 8, 16))
        #expect(try parser.parse("in half an hour", now: now) == local(13, 8, 45))
        #expect(try parser.parse("in a couple of hours", now: now) == local(13, 10, 15))
        #expect(try parser.parse("in a few hours", now: now) == local(13, 11, 15))
        #expect(try parser.parse("in a day", now: now) == local(14, 8, 15))
        #expect(try parser.parse("in a week", now: now) == local(20, 8, 15))
    }

    @Test func theDateGridTakesOnlyAClockTime() {
        #expect(throws: WhenParserError.self) { try parser.parse("later", now: local(13, 0), relativeToNow: false) }
    }

    @Test func eveningHourFollowsSettings() throws {
        let p = WhenParser(timeZone: Self.tz, eveningHour: 19)
        #expect(try p.parse("tonight", now: local(13, 8)) == local(13, 19))
        #expect(p.laterToday(now: local(13, 18, 30))?.date == local(13, 19))
        #expect(p.laterToday(now: local(13, 19, 30)) == nil)
    }
}
