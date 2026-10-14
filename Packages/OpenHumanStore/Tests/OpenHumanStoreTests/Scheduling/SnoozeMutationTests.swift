import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct SnoozeMutationTests {
    private let marker = OHGmailLabels.snoozed

    private func key(_ f: MutationFixture, _ name: String) throws -> String {
        try #require(try f.raw("SELECT key FROM labels WHERE name = ?", [name]).first?["key"] as String?)
    }

    @Test func aFreshSnoozeWorksOfflineWithChainedLabelCreation() throws {
        let f = try MutationFixture()
        let refs = try f.seed(2)
        let receipt = try f.store.apply(.snooze([refs[0]], until: nine.addingTimeInterval(42)), origin: .app)
        #expect(receipt.operationIDs.count == 3 && receipt.undo == .unsnooze([refs[0]]))
        let (markerOp, stampOp, modify) = (try f.op(receipt.operationIDs[0]), try f.op(receipt.operationIDs[1]),
                                           try f.op(receipt.operationIDs[2]))
        #expect(markerOp.payload == .createLabel(name: marker) && markerOp.dependsOn == nil)
        #expect(stampOp.payload == .createLabel(name: snooze9) && stampOp.dependsOn == markerOp.id)
        #expect(modify.payload == .modifyLabels(ids: [GmailMessageID("m1")], add: [], remove: [GmailLabelID("INBOX")],
                                                addNames: [marker, snooze9]))
        #expect(modify.dependsOn == stampOp.id)
        #expect(modify.coalesceKey == "labels:\(f.account.rawValue):|INBOX|\(marker),\(snooze9)")
        let row = try #require(try f.snoozeRow("t1"))
        #expect(row["status"] as String == "active" && row["wake_at"] as Int64? == epochMillis(nine))
        #expect(try f.inbox() == ["t2"] && f.view(.snoozed) == ["t1"] && f.store.thread(refs[0])?.snoozedUntil == nine)
        #expect(try f.claim().map(\.id) == [markerOp.id])
        try f.store.release(markerOp.id, retryAt: Date())
        let done = try f.drain()
        #expect(done.map(\.id) == [markerOp.id, stampOp.id, modify.id])
        let m1 = try f.server("m1")
        #expect(try m1 == [key(f, marker), key(f, snooze9), "UNREAD"])
        #expect(try f.snoozeRow("t1")?["status"] as String? == "active" && f.ops([.pending, .inFlight]).isEmpty)
        #expect(try f.store.label(account: f.account, key: key(f, snooze9))?.isHidden == true)
    }

    @Test func existingLabelsNeedNoCreationAndTheSameStampIsANoOp() throws {
        let f = try MutationFixture()
        try f.labels([("L_mark", marker), ("L_s9", snooze9)])
        let refs = try f.seed(1)
        let receipt = try f.store.apply(.snooze(refs, until: nine), origin: .app)
        #expect(try f.op(try #require(receipt.operationIDs.first)).payload == .modifyLabels(
            ids: [GmailMessageID("m1")], add: [GmailLabelID("L_mark"), GmailLabelID("L_s9")], remove: [GmailLabelID("INBOX")],
            addNames: []))
        #expect(receipt.operationIDs.count == 1)
        let same = try f.store.apply(.snooze(refs, until: nine.addingTimeInterval(59)), origin: .app)
        #expect(same.operationIDs.isEmpty && same.undo == nil)
    }

    @Test func undoWhilePendingLeavesNoOpNoRowNoLabelAndRedoSnoozesAgain() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        let receipt = try f.store.apply(.snooze(refs, until: nine), origin: .app)
        let redo = try #require(try f.store.undo(receipt, origin: .app))
        #expect(redo.operationIDs.isEmpty && redo.undo == .snooze(refs, until: nine))
        #expect(try f.ops([.pending, .inFlight]).isEmpty && f.snoozeRow("t1") == nil && f.inbox() == ["t1"])
        #expect(try receipt.operationIDs.map { try f.op($0).status } == [.cancelled, .cancelled, .cancelled])
        let again = try #require(try f.store.undo(redo, origin: .app))
        #expect(try again.operationIDs.count == 3 && f.snoozeRow("t1") != nil)
    }

    @Test func rescheduleAfterSuccessSwapsStampsAndUndoRestoresTheExactOldName() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        _ = try f.store.apply(.snooze(refs, until: nine), origin: .app)
        try f.drain()
        let k9 = try key(f, snooze9), kMark = try key(f, marker)
        let reschedule = try f.store.apply(.snooze(refs, until: ten), origin: .app)
        #expect(reschedule.undo == .snooze(refs, until: nine))
        let ops = try reschedule.operationIDs.map { try f.op($0) }
        #expect(ops.map(\.kind) == [.createLabel, .modifyLabels])
        #expect(ops[1].payload == .modifyLabels(ids: [GmailMessageID("m1")], add: [GmailLabelID(kMark)],
                                                remove: [GmailLabelID("INBOX"), GmailLabelID(k9)], addNames: [snooze10]))
        #expect(try f.snoozeRow("t1")?["wake_at"] as Int64? == epochMillis(ten))
        try f.drain()
        let k10 = try key(f, snooze10)
        #expect(try f.server("m1") == [kMark, k10, "UNREAD"])
        let undone = try #require(try f.store.undo(reschedule, origin: .app))
        #expect(try f.op(undone.operationIDs[0]).payload == .modifyLabels(
            ids: [GmailMessageID("m1")], add: [GmailLabelID(kMark), GmailLabelID(k9)],
            remove: [GmailLabelID("INBOX"), GmailLabelID(k10)], addNames: []))
        #expect(undone.undo == .snooze(refs, until: ten))
        try f.drain()
        #expect(try f.server("m1") == [kMark, k9, "UNREAD"] && f.snoozeRow("t1")?["wake_at"] as Int64? == epochMillis(nine))
    }

    @Test func rescheduleOfflineReplacesAStampThatWasNeverCreated() throws {
        let f = try MutationFixture()
        let refs = try f.seed(2)
        let first = try f.store.apply(.snooze(refs, until: nine), origin: .app)
        _ = try f.store.apply(.snooze([refs[0]], until: ten), origin: .app)
        #expect(try f.snoozeRow("t1")?["wake_at"] as Int64? == epochMillis(ten))
        #expect(try f.snoozeRow("t1")?["stamp_label_count"] as Int? == 1)
        #expect(try f.snoozeRow("t2")?["wake_at"] as Int64? == epochMillis(nine))
        #expect(try f.op(first.operationIDs[2]).payload == .modifyLabels(
            ids: [GmailMessageID("m2")], add: [], remove: [GmailLabelID("INBOX")], addNames: [marker, snooze9]))
        try f.drain()
        #expect(try f.server("m1") == [key(f, marker), key(f, snooze10), "UNREAD"])
        #expect(try f.server("m2") == [key(f, marker), key(f, snooze9), "UNREAD"])
    }

    @Test func rescheduleOfflineOfTheOnlyThreadCancelsTheOldOpAndItsLabel() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        let first = try f.store.apply(.snooze(refs, until: nine), origin: .app)
        _ = try f.store.apply(.snooze(refs, until: ten), origin: .app)
        #expect(try first.operationIDs.map { try f.op($0).status } == [.pending, .cancelled, .cancelled])
        #expect(try f.op(first.operationIDs[2]).lastErrorCode == "superseded")
        try f.drain()
        #expect(try f.raw("SELECT name FROM labels WHERE name LIKE 'OpenHuman/%' ORDER BY name").map { $0["name"] as String }
            == [marker, snooze10])
        #expect(try f.store.undo(first, origin: .app) == nil)
    }

    @Test func unsnoozeWakesNowAndUndoesToTheOldWake() throws {
        let f = try MutationFixture()
        let refs = try f.seed(2)
        _ = try f.store.apply(.snooze([refs[0]], until: nine), origin: .app)
        try f.drain()
        let (kMark, k9) = (try key(f, marker), try key(f, snooze9))
        _ = try f.store.apply(.markRead([refs[0]]), origin: .app)
        let wake = try f.store.apply(.unsnooze([refs[0]]), origin: .app)
        #expect(wake.undo == .snooze([refs[0]], until: nine))
        guard case let .modifyLabels(ids, add, remove, names) = try f.op(wake.operationIDs[0]).payload else {
            Issue.record("payload"); return
        }
        #expect(ids == [GmailMessageID("m1")] && add == [GmailLabelID("INBOX"), GmailLabelID("UNREAD")] && names.isEmpty)
        #expect(Set(remove.map(\.rawValue)) == [kMark, k9])
        #expect(try f.inbox().first == "t1" && f.snoozeRow("t1") == nil)
        #expect(try (f.threadRow("t1")["sort_boost_at"] as Int64?) != nil)
        try f.drain()
        try f.setting(markUnread: false)
        _ = try f.store.apply(.snooze([refs[1]], until: nine), origin: .app)
        try f.drain()
        let quiet = try f.store.apply(.unsnooze([refs[1]]), origin: .app)
        guard case let .modifyLabels(_, add, _, _) = try f.op(quiet.operationIDs[0]).payload else { Issue.record("payload"); return }
        #expect(add == [GmailLabelID("INBOX")])
        #expect(try f.store.apply(.unsnooze([refs[1]]), origin: .app) == ActionReceipt(operationIDs: []))
    }

    @Test func unsnoozingAMalformedSnoozeIsNotUndoable() throws {
        let f = try MutationFixture()
        try f.labels([("L_mark", marker), ("L_bad", "OpenHuman/Snoozed/someday")])
        try f.upsert([.fixture("m1", thread: "t1", labels: ["L_mark", "L_bad"]),
                      .fixture("m2", thread: "t2", labels: ["L_mark", "L_bad"])])
        let t1 = try f.ref("t1"), t2 = try f.ref("t2")
        #expect(try f.snoozeRow("t1")?["status"] as String? == "malformed")
        let wake = try f.store.apply(.unsnooze([t1]), origin: .app)
        #expect(wake.undo == nil && wake.operationIDs.count == 1)
        guard case let .modifyLabels(_, _, remove, _) = try f.op(wake.operationIDs[0]).payload else { Issue.record("payload"); return }
        #expect(Set(remove.map(\.rawValue)) == ["L_mark", "L_bad"])
        let again = try f.store.apply(.snooze([t2], until: nine), origin: .app)
        guard case let .modifyLabels(_, _, removed, _) = try f.op(try #require(again.operationIDs.last)).payload else {
            Issue.record("payload"); return
        }
        #expect(removed.contains(GmailLabelID("L_bad")) && again.undo == nil)
    }

    @Test func theScheduleLabelBudgetRefusesNewStampsOnly() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try f.store.write { db in
            for i in 0..<SnoozeMutations.scheduleLabelLimit {
                let name = ScheduleLabel(kind: i % 2 == 0 ? .snoozed : .scheduled, due: base.addingTimeInterval(Double(i) * 60)).name
                try db.execute(sql: """
                    INSERT INTO labels (account_id, key, kind, name, display_name, is_hidden, updated_at)
                    VALUES (?, ?, 'user', ?, ?, 1, 0)
                    """, arguments: [f.account.rawValue, "L_b\(i)", name, name])
            }
        }
        #expect(throws: StoreError.limitExceeded("labels")) { try f.store.apply(.snooze(refs, until: nine), origin: .app) }
        #expect(try f.inbox() == ["t1"] && f.ops().isEmpty)
        let existing = try f.store.apply(.snooze(refs, until: base), origin: .app)
        #expect(try !existing.operationIDs.isEmpty && f.snoozeRow("t1") != nil)
    }

    @Test func clearingASnoozeLeavesTheConversationWhereItIsAndUndoBringsTheWakeBack() throws {
        let f = try MutationFixture()
        let refs = try f.seed(2)
        _ = try f.store.apply(.snooze([refs[0]], until: nine), origin: .app)
        try f.drain()
        let (kMark, k9) = (try key(f, marker), try key(f, snooze9))
        let clear = try f.store.apply(.clearSnooze([refs[0]]), origin: .app)
        #expect(clear.undo == .snooze([refs[0]], until: nine))
        guard case let .modifyLabels(ids, add, remove, names) = try f.op(try #require(clear.operationIDs.first)).payload
        else { Issue.record("payload"); return }
        #expect(ids == [GmailMessageID("m1")] && add.isEmpty && names.isEmpty && Set(remove.map(\.rawValue)) == [kMark, k9])
        #expect(try f.snoozeRow("t1") == nil && f.inbox() == ["t2"] && f.view(.snoozed).isEmpty)
        #expect(try (f.threadRow("t1")["sort_boost_at"] as Int64?) == nil, "not a wake")
        let redo = try #require(try f.store.undo(clear, origin: .app))
        #expect(try redo.undo == .clearSnooze([refs[0]]) && f.snoozeRow("t1")?["wake_at"] as Int64? == epochMillis(nine))
        let again = try #require(try f.store.undo(redo, origin: .app))
        #expect(try f.snoozeRow("t1") == nil && f.inbox() == ["t2"])
        try f.drain()
        #expect(try f.server("m1") == ["UNREAD"])
        let restored = try #require(try f.store.undo(again, origin: .app))
        try f.drain()
        #expect(try f.server("m1") == [kMark, k9, "UNREAD"] && f.view(.snoozed) == ["t1"] && f.inbox() == ["t2"])
        _ = try #require(try f.store.undo(restored, origin: .app))
        #expect(try f.snoozeRow("t1") == nil && f.inbox() == ["t2"], "redo does not wake it into the Inbox")
        #expect(try f.store.apply(.clearSnooze([refs[1]]), origin: .app) == ActionReceipt(operationIDs: []))
    }

    @Test func archivingASnoozedThreadKeepsTheSnooze() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        _ = try f.store.apply(.snooze(refs, until: nine), origin: .app)
        try f.drain()
        _ = try f.store.apply(.moveToInbox(refs), origin: .app)
        let done = try f.store.apply(.archive(refs), origin: .app)
        #expect(try f.op(done.operationIDs[0]).payload == .modifyLabels(ids: [GmailMessageID("m1")], add: [],
                                                                        remove: [GmailLabelID("INBOX")], addNames: []))
        #expect(try f.snoozeRow("t1")?["status"] as String? == "active")
    }
}

@Suite struct SnoozeSchedulerTests {
    private let marker = OHGmailLabels.snoozed

    private func setup() throws -> MutationFixture {
        let f = try MutationFixture()
        try f.labels([("L_mark", marker), ("L_s9", snooze9), ("L_s10", snooze10)])
        try f.upsert([.fixture("m1", thread: "t1", minutes: 1, labels: ["L_mark", "L_s9"]),
                      .fixture("m2", thread: "t2", minutes: 2, labels: ["L_mark", "L_s10"]),
                      .fixture("m3", thread: "t3", minutes: 3, labels: ["L_mark", "L_s10"]),
                      .fixture("m3b", thread: "t3", minutes: 4, labels: ["L_mark", "L_s9"]),
                      .fixture("m4", thread: "t4", minutes: 5, labels: ["L_mark", "L_s10"]),
                      .fixture("m4b", thread: "t4", minutes: 6, labels: ["INBOX", "UNREAD"], from: "bob@example.com")])
        return f
    }

    @Test func dueItemsSortSnoozesIntoWakeWokenByMailAndNormalize() throws {
        let f = try setup()
        let early = try f.store.dueItems(account: f.account, now: nine.addingTimeInterval(-60))
        #expect(early.snoozesToWake.isEmpty)
        #expect(early.snoozesWokenByMail.map(\.0.gmailThreadID.rawValue) == ["t4"])
        #expect(early.snoozesToNormalize.map(\.0.gmailThreadID.rawValue) == ["t3"])
        let atNine = try f.store.dueItems(account: f.account, now: nine)
        #expect(atNine.snoozesToWake.map(\.0.gmailThreadID.rawValue) == ["t1", "t3"])
        #expect(atNine.snoozesToWake[0].1 == SnoozeInfo(wakeAt: nine, labelName: snooze9, stampLabelCount: 1))
        #expect(atNine.snoozesToWake[1].1.stampLabelCount == 2)
        #expect(try f.store.nextDueTime(account: f.account, kinds: [.snooze]) == nine)
        #expect(try f.store.nextDueTime(account: f.account, kinds: [.reminder]) == nil)
    }

    @Test func normalizeKeepsTheEarliestStampOfAThreadNotYetDue() throws {
        let f = try MutationFixture()
        try f.labels([("L_mark", marker), ("L_s9", snooze9), ("L_s10", snooze10)])
        try f.upsert([.fixture("m3", thread: "t3", minutes: 3, labels: ["L_mark", "L_s10"]),
                      .fixture("m3b", thread: "t3", minutes: 4, labels: ["L_mark", "L_s9"])])
        let due = try f.store.dueItems(account: f.account, now: nine.addingTimeInterval(-3600))
        #expect(due.snoozesToNormalize.map(\.0.gmailThreadID.rawValue) == ["t3"])
        let ref = due.snoozesToNormalize[0].0
        let receipt = try f.store.normalizeSnooze(ref, keep: snooze9, remove: [snooze9, snooze10],
                                                  messageIDs: [GmailMessageID("m3")])
        let op = try f.op(receipt.operationIDs[0])
        #expect(op.payload == .modifyLabels(ids: [GmailMessageID("m3")], add: [], remove: [GmailLabelID("L_s10")], addNames: []))
        #expect(op.origin == .scheduler && op.coalesceKey == nil && receipt.undo == nil)
        #expect(try f.snoozeRow("t3")?["stamp_label_count"] as Int? == 1)
        #expect(try f.store.normalizeSnooze(ref, keep: snooze9, remove: [snooze10], messageIDs: [GmailMessageID("m3")]).operationIDs.isEmpty)
    }

    @Test func wakeIsOneSchedulerOpAndIdempotent() throws {
        let f = try setup()
        let t1 = try f.ref("t1")
        let receipt = try f.store.wakeSnooze(t1, confirmedLabels: [snooze9], messageIDs: [GmailMessageID("m1")], now: nine)
        let op = try f.op(try #require(receipt.operationIDs.first))
        #expect(op.payload == .modifyLabels(ids: [GmailMessageID("m1")], add: [GmailLabelID("INBOX"), GmailLabelID("UNREAD")],
                                            remove: [GmailLabelID("L_mark"), GmailLabelID("L_s9")], addNames: []))
        #expect(op.origin == .scheduler && op.coalesceKey == nil && op.notBefore == nine && receipt.undo == nil)
        #expect(try f.threadRow("t1")["sort_boost_at"] as Int64? == epochMillis(nine))
        #expect(try f.snoozeRow("t1") == nil && f.inbox().contains("t1"))
        #expect(try f.store.wakeSnooze(t1, confirmedLabels: [snooze9], messageIDs: [GmailMessageID("m1")], now: nine).operationIDs.isEmpty)
        #expect(try !f.store.dueItems(account: f.account, now: nine).snoozesToWake.map(\.0).contains(t1))
        #expect(try f.store.undo(receipt, origin: .app) == nil && f.op(op.id).status == .pending)
        try f.drain(now: nine.addingTimeInterval(1))
        #expect(try f.server("m1") == ["INBOX", "UNREAD"])
    }

    @Test func aWakeAlreadyAppliedByTheOtherMacQueuesNothing() throws {
        let f = try setup()
        _ = try f.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("m1"), historyID: HistoryID(9),
                                                     added: [GmailLabelID("INBOX")],
                                                     removed: [GmailLabelID("L_mark"), GmailLabelID("L_s9")])],
                                         account: f.account)
        let receipt = try f.store.wakeSnooze(try f.ref("t1"), confirmedLabels: [snooze9], messageIDs: [GmailMessageID("m1")], now: nine)
        #expect(try receipt.operationIDs.isEmpty && f.ops().isEmpty)
    }

    @Test func clearRemovesTheSnoozeOfAThreadWokenByMail() throws {
        let f = try setup()
        let item = try #require(try f.store.dueItems(account: f.account, now: nine).snoozesWokenByMail.first)
        let receipt = try f.store.clearSnooze(item.0, confirmedLabels: [try #require(item.1.labelName)],
                                              messageIDs: [GmailMessageID("m4")])
        #expect(try f.op(receipt.operationIDs[0]).payload == .modifyLabels(
            ids: [GmailMessageID("m4")], add: [], remove: [GmailLabelID("L_mark"), GmailLabelID("L_s10")], addNames: []))
        #expect(try f.snoozeRow("t4") == nil && f.inbox().contains("t4"))
        #expect(try f.store.dueItems(account: f.account, now: nine).snoozesWokenByMail.isEmpty)
    }
}
