import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

private typealias M = ScheduleDerivation.MessageLabels
private let s9 = "OpenHuman/Snoozed/20261012T0900Z"
private let s10 = "OpenHuman/Snoozed/20261012T1000Z"

@Suite struct SnoozeDerivationTableTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var messages: [(Bool, [String])]
        var expected: (ScheduleDerivation.Snooze.Status, String?, Int)?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "no labels", messages: [(true, ["INBOX"])], expected: nil),
        Case(name: "one stamp", messages: [(true, [s9, "OpenHuman/Snoozed"])], expected: (.active, s9, 1)),
        Case(name: "two stamps, earliest wins", messages: [(true, [s10]), (true, [s9])], expected: (.active, s9, 2)),
        Case(name: "same stamp twice counts once", messages: [(true, [s9]), (true, [s9])], expected: (.active, s9, 1)),
        Case(name: "marker only", messages: [(true, ["OpenHuman/Snoozed"])], expected: (.malformed, nil, 0)),
        Case(name: "malformed stamp", messages: [(true, ["OpenHuman/Snoozed/2026-10-12"])], expected: (.malformed, nil, 0)),
        Case(name: "stamp beats malformed", messages: [(true, ["OpenHuman/Snoozed/x", s10])], expected: (.active, s10, 1)),
        Case(name: "stamp on a draft only", messages: [(false, [s9]), (true, ["INBOX"])], expected: nil),
        Case(name: "send-later stamp is not a snooze", messages: [(true, ["OpenHuman/Scheduled/20261012T0900Z"])],
             expected: nil),
        Case(name: "lowercase kind is not ours", messages: [(true, ["OpenHuman/snoozed/20261012T0900Z"])], expected: nil),
    ]

    @Test(arguments: cases) func derive(_ c: Case) throws {
        let got = try ScheduleDerivation.deriveSnoozes(c.messages.map { M(visible: $0.0, names: $0.1) })
        if let (status, name, count) = c.expected {
            #expect(got?.status == status && got?.labelName == name && got?.stampLabelCount == count)
            #expect((got?.wakeAt == nil) == (status == .malformed))
            if let name { #expect(got?.wakeAt == millis(String(name.suffix(14)))) }
        } else {
            #expect(got == nil)
        }
    }
}

@Suite struct ScheduledSendDerivationTableTests {
    private typealias D = ScheduleDerivation.DraftSchedule
    private static let stamp = "20261012T0900Z"
    private static let label = "OpenHuman/Scheduled/20261012T0900Z"

    private func derive(state: DraftState = .editing, sendAt: Int64? = nil, error: String? = nil, dirty: Bool = false,
                        header: String?, labels: [String] = [], remoteChanged: Bool = false) throws -> D {
        try ScheduleDerivation.deriveScheduledSend(.init(isDirty: dirty, current: D(state: state, sendAt: sendAt, lastError: error),
                                                         header: header, labelNames: labels, remoteChanged: remoteChanged))
    }

    @Test func headerAndLabelAgree() throws {
        #expect(try derive(header: Self.stamp, labels: ["OpenHuman/Scheduled", Self.label])
            == D(state: .scheduled, sendAt: millis(Self.stamp), lastError: nil))
    }

    @Test func headerWithoutLabelIsStillScheduled() throws {
        #expect(try derive(header: " \(Self.stamp) ").state == .scheduled)
        #expect(try derive(header: Self.stamp, labels: ["OpenHuman/Scheduled/garbage"]).sendAt == millis(Self.stamp))
    }

    @Test func labelWithoutHeaderNeverSchedules() throws {
        #expect(try derive(header: nil, labels: [Self.label]) == D(state: .editing, sendAt: nil, lastError: nil))
        #expect(try derive(state: .scheduled, sendAt: 5, header: nil, labels: [Self.label]).state == .editing)
    }

    @Test func malformedHeaderOrLabelFails() throws {
        let unreadable = D(state: .failed, sendAt: nil, lastError: ScheduleDerivation.unreadableScheduleError)
        #expect(try derive(header: "2026-10-12T09:00Z") == unreadable)
        #expect(try derive(header: nil, labels: ["OpenHuman/Scheduled/tomorrow"]) == unreadable)
        #expect(try derive(state: .failed, error: ScheduleDerivation.unreadableScheduleError, header: Self.stamp).state == .scheduled)
        #expect(try derive(state: .failed, error: ScheduleDerivation.unreadableScheduleError, header: nil).state == .editing)
    }

    @Test func localIntentAndForeignFailuresAreKept() throws {
        let dirty = D(state: .scheduled, sendAt: 42, lastError: nil)
        #expect(try derive(state: .scheduled, sendAt: 42, dirty: true, header: nil) == dirty)
        let missed = D(state: .failed, sendAt: 7, lastError: "scheduled time passed while Mail was closed")
        #expect(try derive(state: .failed, sendAt: 7, error: missed.lastError, header: Self.stamp) == missed)
        #expect(try derive(state: .failed, sendAt: 7, error: missed.lastError, header: Self.stamp, remoteChanged: true)
            == D(state: .scheduled, sendAt: millis(Self.stamp), lastError: nil))
        for state in [DraftState.sending, .sent, .discarded] {
            #expect(try derive(state: state, header: Self.stamp).state == state)
        }
    }
}

@Suite struct SnoozeCacheTests {
    private func setup() throws -> AggregationFixture {
        let f = try AggregationFixture()
        try f.labels([("L_mark", "OpenHuman/Snoozed"), ("L_s9", s9), ("L_s10", s10), ("L_bad", "OpenHuman/Snoozed/soon")])
        try f.upsert([.fixture("m1", thread: "t1", minutes: 0, labels: ["INBOX", "UNREAD"], history: 10),
                      .fixture("m2", thread: "t1", minutes: 1, labels: ["INBOX"], history: 10)])
        return f
    }

    @Test func freshSnoozeThroughThePendingOpShowsAtOnceAndAFailedOpRemovesIt() throws {
        let f = try setup()
        let op = try f.op(["m1", "m2"], add: ["L_mark", "L_s9"], remove: ["INBOX"])
        #expect(try f.snooze("t1") == .init(status: .active, wakeAt: millis("20261012T0900Z"), labelName: s9, stampLabelCount: 1))
        #expect(try f.inbox().isEmpty && f.view(.system(f.account, .snoozed)) == ["t1"])
        #expect(try f.sortKeys("t1")["oh:snoozed"] == millis("20261012T0900Z"))
        let item = try #require(try f.store.thread(f.ref("t1")))
        #expect(item.snoozedUntil == Date(timeIntervalSince1970: Double(millis("20261012T0900Z")) / 1000))
        try f.store.fail(OperationID(rawValue: op), code: "bad_request", message: "x", retryAt: nil)
        #expect(try f.snooze("t1") == nil && f.inbox() == ["t1"])
        #expect(try f.view(.system(f.account, .snoozed)).isEmpty)
        #expect(try f.threadRow("t1")["snoozed_until"] as Int64? == nil)
    }

    @Test func aBrandNewStampWithoutALabelRowShowsThroughAddNames() throws {
        let f = try setup()
        let fresh = "OpenHuman/Snoozed/20261013T0800Z"
        _ = try f.op(["m1", "m2"], add: ["L_mark"], remove: ["INBOX"], addNames: [fresh])
        #expect(try f.snooze("t1")?.labelName == fresh && f.snooze("t1")?.status == .active)
        try f.labels([("L_fresh", fresh)])
        let m1 = try #require(try f.store.message(account: f.account, gmailMessageID: GmailMessageID("m1")))
        #expect(m1.labelIDs.contains(GmailLabelID("L_fresh")))
        #expect(try f.snooze("t1")?.wakeAt == millis("20261013T0800Z"))
    }

    @Test func twoStampsEarliestWinsAndMarkerOrMalformedIsMalformed() throws {
        let f = try setup()
        _ = try f.op(["m1"], add: ["L_mark", "L_s10"], remove: ["INBOX"])
        _ = try f.op(["m2"], add: ["L_mark", "L_s9"], remove: ["INBOX"])
        #expect(try f.snooze("t1") == .init(status: .active, wakeAt: millis("20261012T0900Z"), labelName: s9, stampLabelCount: 2))

        try f.upsert([.fixture("x1", thread: "tx", labels: ["L_mark"], history: 10)])
        #expect(try f.snooze("tx") == .init(status: .malformed, wakeAt: nil, labelName: nil, stampLabelCount: 0))
        #expect(try f.sortKeys("tx")["oh:snoozed"] == 0)
        try f.upsert([.fixture("y1", thread: "ty", labels: ["L_bad"], history: 10)])
        #expect(try f.snooze("ty")?.status == .malformed)
    }

    @Test func renamingTheStampLabelMovesOrBreaksTheSnooze() throws {
        let f = try setup()
        _ = try f.op(["m1", "m2"], add: ["L_mark", "L_s9"], remove: ["INBOX"])
        try f.labels([("L_s9", "OpenHuman/Snoozed/20261020T0700Z")])
        #expect(try f.snooze("t1")?.wakeAt == millis("20261020T0700Z"))
        try f.labels([("L_s9", "Later")])
        #expect(try f.snooze("t1")?.status == .malformed)
        #expect(try f.store.label(account: f.account, key: "L_s9")?.isHidden == false)
        #expect(try f.store.thread(f.ref("t1"))?.userLabelIDs.isEmpty == false)
    }

    @Test func deletedLabelRowsRemoveTheSnooze() throws {
        let f = try setup()
        try f.upsert([.fixture("m1", thread: "t1", minutes: 0, labels: ["L_s9"], history: 11),
                      .fixture("m2", thread: "t1", minutes: 1, labels: ["L_s9"], history: 11)])
        #expect(try f.snooze("t1")?.status == .active)
        try f.labels([], removeMissing: true)
        #expect(try f.snooze("t1") == nil && f.view(.system(f.account, .snoozed)).isEmpty)
    }

    @Test func stampsOnDraftsOrTrashedMessagesDoNotCount() throws {
        let f = try setup()
        try f.upsert([.fixture("d1", thread: "td", labels: ["DRAFT", "L_s9"], history: 10),
                      .fixture("d2", thread: "td", minutes: 1, labels: ["INBOX"], history: 10),
                      .fixture("z1", thread: "tz", labels: ["TRASH", "L_s9"], history: 10)])
        #expect(try f.snooze("td") == nil && f.snooze("tz") == nil)
    }

    @Test func newInboxMailOnASnoozedThreadKeepsTheRowForTheScheduler() throws {
        let f = try setup()
        try f.upsert([.fixture("m1", thread: "t1", labels: ["L_mark", "L_s9"], history: 11),
                      .fixture("m2", thread: "t1", minutes: 1, labels: ["L_mark", "L_s9"], history: 11)])
        #expect(try f.inbox().isEmpty)
        try f.upsert([.fixture("m3", thread: "t1", minutes: 30, labels: ["INBOX", "UNREAD"], history: 12)])
        #expect(try f.snooze("t1")?.status == .active && f.inbox() == ["t1"])
        #expect(try f.threadRow("t1")["in_inbox"] as Bool)
    }

    @Test func aWakeSeenThroughHistoryJumpsToTheTopOfTheInbox() throws {
        let f = try setup()
        try f.upsert([.fixture("m1", thread: "t1", minutes: 0, labels: ["L_mark", "L_s9"], history: 11),
                      .fixture("m2", thread: "t1", minutes: 1, labels: ["L_mark", "L_s9"], history: 11),
                      .fixture("n1", thread: "tn", minutes: 500, labels: ["INBOX"], history: 11)])
        #expect(try f.inbox() == ["tn"])
        _ = try f.store.applyLabelDeltas(["m1", "m2"].map {
            LabelDelta(gmailMessageID: GmailMessageID($0), historyID: HistoryID(12), added: [GmailLabelID("INBOX")],
                       removed: [GmailLabelID("L_mark"), GmailLabelID("L_s9")])
        }, account: f.account)
        #expect(try f.snooze("t1") == nil)
        #expect(try f.inbox() == ["t1", "tn"])
        #expect(try (f.threadRow("t1")["sort_boost_at"] as Int64?) != nil)
        try f.upsert([.fixture("m3", thread: "t1", minutes: Int(Date().timeIntervalSince1970 / 60) + 10, labels: ["INBOX"],
                               history: 13)])
        #expect(try (f.threadRow("t1")["sort_boost_at"] as Int64?) == nil)
    }

    @Test func hiddenLabelsStayOutOfChipsLabelListsAndSplits() throws {
        let f = try setup()
        try f.mutate { db in
            try db.execute(sql: "UPDATE splits SET rule_json = ? WHERE account_id = ?", arguments: [
                String(decoding: try JSONEncoder().encode(SplitRule.or([.label("OpenHuman/Snoozed"), .label(s9),
                                                                        .label("L_s9")])), as: UTF8.self),
                f.account.rawValue])
        }
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX", "L_mark", "L_s9"], history: 11)])
        let item = try #require(try f.store.thread(f.ref("t1")))
        #expect(item.userLabelIDs.isEmpty)
        #expect(try f.store.label(account: f.account, key: "L_mark")?.isHidden == true)
        #expect(try f.store.label(account: f.account, key: "L_s9")?.isHidden == true)
        #expect(try f.store.label(account: f.account, key: "L_bad")?.isHidden == false)
        #expect(try f.keys("t1").contains("oh:split:other"))
    }
}

@Suite struct ScheduledSendCacheTests {
    private static let stamp = "20261012T0900Z"

    private func scheduledThread(headers: [String: String], labels: [String]) throws -> AggregationFixture {
        let f = try AggregationFixture()
        try f.labels([("L_sch", "OpenHuman/Scheduled"), ("L_sch9", "OpenHuman/Scheduled/\(Self.stamp)"),
                      ("L_schbad", "OpenHuman/Scheduled/oops")])
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX"], history: 10),
                      .fixture("dm1", thread: "t1", minutes: 5, labels: ["DRAFT"] + labels, from: "me@example.com", history: 10)])
        try f.store.reconcileRemoteDrafts([f.remote("r1", message: "dm1", thread: "t1", headers: headers)],
                                          account: f.account, complete: true)
        return f
    }

    @Test func headerAndLabelAgree() throws {
        let f = try scheduledThread(headers: ["X-OpenHuman-Send-At": Self.stamp], labels: ["L_sch", "L_sch9"])
        let row = try #require(try f.draftRow(gmailDraftID: "r1"))
        #expect(row["state"] as String == "scheduled" && row["send_at"] as Int64? == millis(Self.stamp))
        #expect(try f.threadRow("t1")["scheduled_send_at"] as Int64? == millis(Self.stamp))
        #expect(try f.view(.system(f.account, .scheduled)) == ["t1"])
        #expect(try f.sortKeys("t1")["oh:scheduled"] == millis(Self.stamp))
        #expect(try f.store.thread(f.ref("t1"))?.scheduledSendAt != nil)
    }

    @Test func headerWithoutLabelIsScheduledAndLabelWithoutHeaderIsNot() throws {
        let a = try scheduledThread(headers: ["x-openhuman-send-at": Self.stamp], labels: [])
        #expect(try a.draftRow(gmailDraftID: "r1")?["state"] as String? == "scheduled")
        let b = try scheduledThread(headers: [:], labels: ["L_sch", "L_sch9"])
        #expect(try b.draftRow(gmailDraftID: "r1")?["state"] as String? == "editing")
        #expect(try b.view(.system(b.account, .scheduled)).isEmpty)
    }

    @Test func malformedHeaderOrLabelFails() throws {
        let a = try scheduledThread(headers: ["X-OpenHuman-Send-At": "tomorrow"], labels: [])
        #expect(try a.draftRow(gmailDraftID: "r1")?["state"] as String? == "failed")
        #expect(try a.draftRow(gmailDraftID: "r1")?["last_error"] as String? == ScheduleDerivation.unreadableScheduleError)
        let b = try scheduledThread(headers: [:], labels: [])
        _ = try b.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("dm1"), historyID: HistoryID(11),
                                                     added: [GmailLabelID("L_schbad")], removed: [])], account: b.account)
        #expect(try b.draftRow(gmailDraftID: "r1")?["state"] as String? == "failed")
    }

    @Test func aDirtyLocalRowKeepsItsOwnSendAt() throws {
        let f = try scheduledThread(headers: ["X-OpenHuman-Send-At": Self.stamp], labels: ["L_sch", "L_sch9"])
        let mine = millis("20261015T1200Z")
        try f.mutate { db in
            try db.execute(sql: """
                UPDATE drafts SET state = 'scheduled', send_at = ?, local_version = local_version + 1,
                    extra_headers_json = '{"X-OpenHuman-Send-At":"20261015T1200Z"}'
                """, arguments: [mine])
        }
        _ = try f.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("dm1"), historyID: HistoryID(11),
                                                     added: [], removed: [GmailLabelID("L_sch9")])], account: f.account)
        try f.store.reconcileRemoteDrafts([f.remote("r1", message: "dm2", thread: "t1",
                                                    headers: ["X-OpenHuman-Send-At": Self.stamp])],
                                          account: f.account, complete: true)
        let row = try #require(try f.draftRow(gmailDraftID: "r1"))
        #expect(row["send_at"] as Int64? == mine && row["state"] as String == "scheduled")
        #expect(try f.threadRow("t1")["scheduled_send_at"] as Int64? == mine)
    }
}

#if DEBUG
@Suite struct DerivationIsolationTests {
    @Test func aThrowingSnoozeDerivationLeavesItsCacheAndCommitsTheRest() throws {
        let f = try AggregationFixture()
        let s9 = "OpenHuman/Snoozed/20261012T0900Z"
        try f.labels([("L_mark", "OpenHuman/Snoozed"), ("L_s9", s9)])
        try f.upsert([.fixture("m1", thread: "t-iso-snooze", labels: ["L_mark", "L_s9"], history: 10)])
        let before = try #require(try f.snooze("t-iso-snooze"))
        DerivationFaults.inject(.snooze, thread: "t-iso-snooze")
        defer { DerivationFaults.clear(.snooze, thread: "t-iso-snooze") }
        _ = try f.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("m1"), historyID: HistoryID(11),
                                                     added: [GmailLabelID("STARRED")],
                                                     removed: [GmailLabelID("L_mark"), GmailLabelID("L_s9")])],
                                         account: f.account)
        #expect(try f.snooze("t-iso-snooze") == before)
        #expect(try f.threadRow("t-iso-snooze")["snoozed_until"] as Int64? == before.wakeAt)
        #expect(try f.keys("t-iso-snooze").contains("oh:snoozed"))
        #expect(try f.threadRow("t-iso-snooze")["is_starred"] as Bool)
        DerivationFaults.clear(.snooze, thread: "t-iso-snooze")
        _ = try f.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("m1"), historyID: HistoryID(12),
                                                     added: [], removed: [])], account: f.account)
        #expect(try f.snooze("t-iso-snooze") == nil)
    }

    @Test func aThrowingSendLaterDerivationLeavesTheDraftsAndCommitsTheRest() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "t-iso-send", labels: ["INBOX"], history: 10),
                      .fixture("dm1", thread: "t-iso-send", minutes: 3, labels: ["DRAFT"], history: 10)])
        try f.store.reconcileRemoteDrafts([f.remote("r1", message: "dm1", thread: "t-iso-send",
                                                    headers: ["X-OpenHuman-Send-At": "20261012T0900Z"])],
                                          account: f.account, complete: true)
        DerivationFaults.inject(.sendLater, thread: "t-iso-send")
        defer { DerivationFaults.clear(.sendLater, thread: "t-iso-send") }
        try f.mutate { db in try db.execute(sql: "UPDATE drafts SET extra_headers_json = '{}'") }
        _ = try f.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("m1"), historyID: HistoryID(11),
                                                     added: [GmailLabelID("STARRED")], removed: [])], account: f.account)
        #expect(try f.draftRow(gmailDraftID: "r1")?["state"] as String? == "scheduled")
        #expect(try f.threadRow("t-iso-send")["scheduled_send_at"] as Int64? == millis("20261012T0900Z"))
        #expect(try f.threadRow("t-iso-send")["is_starred"] as Bool)
    }
}
#endif
