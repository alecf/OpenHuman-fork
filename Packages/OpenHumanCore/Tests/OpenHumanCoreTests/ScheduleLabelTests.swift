import Foundation
import Testing
import OpenHumanCore

@Suite struct ScheduleLabelTests {
    static let oct12_0900Z = Date(timeIntervalSince1970: 1_791_795_600)

    @Test func canonicalNames() {
        #expect(ScheduleLabel(kind: .snoozed, due: Self.oct12_0900Z).name == "OpenHuman/Snoozed/20261012T0900Z")
        #expect(ScheduleLabel(kind: .scheduled, due: Self.oct12_0900Z.addingTimeInterval(59.9)).name
            == "OpenHuman/Scheduled/20261012T0900Z")
        #expect(ScheduleLabel.markerName(.snoozed) == OHGmailLabels.snoozed)
        #expect(ScheduleLabel.markerName(.scheduled) == OHGmailLabels.scheduled)
        #expect("OpenHuman/Scheduled/20261012T0900Z".count == 34)
    }

    @Test func parseCategories() {
        #expect(ScheduleLabel.parse("OpenHuman/Snoozed/20261012T0900Z") ==
            .schedule(ScheduleLabel(kind: .snoozed, due: Self.oct12_0900Z)))
        #expect(ScheduleLabel.parse("OpenHuman/Snoozed") == .marker(.snoozed))
        #expect(ScheduleLabel.parse("OpenHuman/Scheduled") == .marker(.scheduled))
        #expect(ScheduleLabel.parse("OpenHuman/Scheduled/soon") == .malformed(.scheduled))
        #expect(ScheduleLabel.parse("OpenHuman/Agent") == .notOurs)
        #expect(ScheduleLabel.parse("INBOX") == .notOurs)
    }

    @Test func roundTripProperty() {
        var state: UInt64 = 0x5EED
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let start = 946_684_800.0
        let span = 6_311_433_600.0
        var previous: ScheduleLabel?
        for _ in 0..<100_000 {
            let instant = Date(timeIntervalSince1970: start + Double(next() % UInt64(span * 1000)) / 1000)
            let kind: ScheduleLabel.Kind = next() % 2 == 0 ? .snoozed : .scheduled
            let label = ScheduleLabel(kind: kind, due: instant)
            #expect(label.due == ScheduleStamp.floorToMinute(instant))
            guard case let .schedule(parsed) = ScheduleLabel.parse(label.name) else {
                Issue.record("did not parse \(label.name)")
                return
            }
            #expect(parsed == label)
            #expect(parsed.name == label.name)
            if let p = previous, p.kind == label.kind {
                #expect((p.name < label.name) == (p.due < label.due))
            }
            previous = label
        }
    }

    @Test(arguments: [
        "OpenHuman/Snoozed/20261012t0900Z", "OpenHuman/Snoozed/20261012T0900z", "OpenHuman/Snoozed/20261012T090000Z",
        "OpenHuman/Snoozed/20261012T0900+0200", "OpenHuman/Snoozed/2026-10-12T09:00Z", "OpenHuman/Snoozed/20261012T09:00Z",
        "OpenHuman/Snoozed/20260230T0900Z", "OpenHuman/Snoozed/20261012T2400Z", "OpenHuman/Snoozed/20261012T0960Z",
        "OpenHuman/Snoozed/20261312T0900Z", "OpenHuman/Snoozed/20261000T0900Z", "OpenHuman/Snoozed/20261032T0900Z",
        "OpenHuman/Snoozed/20261012T0900Z/", "OpenHuman/Snoozed/ 20261012T0900Z", "OpenHuman/Snoozed/20261012T0900Z ",
        "OpenHuman/Snoozed/２０２６1012T0900Z", "OpenHuman/Snoozed/19991231T2359Z", "OpenHuman/Snoozed/2026101T0900Z",
        "OpenHuman/Snoozed/202610120T900Z", "OpenHuman/Snoozed/", "OpenHuman/Snoozed/20261012", "OpenHuman/Snoozed/T0900Z",
        "OpenHuman/Snoozed/20261012T0900", "OpenHuman/Snoozed/20261012 0900Z", "OpenHuman/Snoozed/2026O1012T0900Z",
        "OpenHuman/Snoozed/20250229T0900Z", "OpenHuman/Snoozed/20261012T-900Z", "OpenHuman/Scheduled/20261012T0900ZZ",
        "OpenHuman/Scheduled/later", "OpenHuman/Scheduled//20261012T0900Z", "OpenHuman/Scheduled/20261012T0900Z/x",
    ])
    func malformed(name: String) {
        if case .malformed = ScheduleLabel.parse(name) {} else {
            Issue.record("expected .malformed for \(name), got \(ScheduleLabel.parse(name))")
        }
    }

    @Test(arguments: [
        "OpenHuman/snoozed/20261012T0900Z", "OpenHuman/Remind/20261012T0900Z", "openhuman/Snoozed/20261012T0900Z",
        "OpenHuman/SnoozedX/20261012T0900Z", "OpenHuman/Snoozed20261012T0900Z", "Snoozed/20261012T0900Z",
        "OpenHuman", "OpenHuman/", "OpenHuman/Agent", "", " OpenHuman/Snoozed", "Work/OpenHuman/Snoozed/20261012T0900Z",
    ])
    func notOurs(name: String) {
        #expect(ScheduleLabel.parse(name) == .notOurs)
    }

    @Test func leapDayIsValid() {
        if case .schedule = ScheduleLabel.parse("OpenHuman/Snoozed/20280229T0000Z") {} else { Issue.record("leap day") }
    }

    @Test func ordering() {
        let a = ScheduleLabel(kind: .scheduled, due: Self.oct12_0900Z)
        let b = ScheduleLabel(kind: .snoozed, due: Self.oct12_0900Z)
        let c = ScheduleLabel(kind: .snoozed, due: Self.oct12_0900Z.addingTimeInterval(60))
        #expect([c, a, b].sorted() == [b, a, c])
        let names = ["INBOX", "OpenHuman/Snoozed", "OpenHuman/Snoozed/20261013T0800Z", "OpenHuman/Snoozed/bad",
                     "OpenHuman/Snoozed/20261012T0900Z", "OpenHuman/Scheduled/20261001T0000Z"]
        #expect(ScheduleLabel.schedules(.snoozed, in: names).map(\.name) ==
            ["OpenHuman/Snoozed/20261012T0900Z", "OpenHuman/Snoozed/20261013T0800Z"])
    }
}

@Suite struct WhenParserDSTTests {
    func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test(arguments: [
        ("Europe/Berlin", "2027-03-27T12:00:00Z", "tomorrow 02:30", "2027-03-28T01:00:00Z"),
        ("America/New_York", "2027-03-13T17:00:00Z", "tomorrow 02:30", "2027-03-14T07:00:00Z"),
        ("Europe/Berlin", "2026-10-24T12:00:00Z", "tomorrow 02:30", "2026-10-25T00:30:00Z"),
        ("America/New_York", "2026-10-31T16:00:00Z", "tomorrow 01:30", "2026-11-01T05:30:00Z"),
    ])
    func dstRules(zone: String, now: String, input: String, expected: String) throws {
        let parser = WhenParser(timeZone: TimeZone(identifier: zone)!)
        let got = try parser.parse(input, now: instant(now))
        #expect(got == instant(expected))
        if case let .schedule(label) = ScheduleLabel.parse(ScheduleLabel(kind: .snoozed, due: got).name) {
            #expect(label.due == got)
        } else { Issue.record("label did not round trip") }
    }
}
