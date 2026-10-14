import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct ReminderTests {
    @Test func setIsLocalMirrorsOnTheThreadAndUndoesToCancel() throws {
        let f = try MutationFixture()
        let refs = try f.seed(2)
        let receipt = try f.store.apply(.setReminder(refs[0], dueAt: nine, condition: .always), origin: .app)
        #expect(receipt.operationIDs.isEmpty && receipt.undo == .cancelReminder(refs[0]))
        #expect(try f.ops().isEmpty)
        let row = try #require(try f.reminders("t1").first)
        #expect(row["state"] as String == "active" && row["due_at"] as Int64 == epochMillis(nine))
        #expect(row["condition"] as String == "always" && row["anchor_message_id"] as String? == "m1")
        #expect(try f.store.thread(refs[0])?.reminderAt == nine && f.view(.reminders) == ["t1"])
        #expect(try f.inbox().count == 2)

        let redo = try #require(try f.store.undo(receipt, origin: .app))
        #expect(try f.reminders("t1").map { $0["state"] as String } == ["cancelled"])
        #expect(try f.store.thread(refs[0])?.reminderAt == nil && f.view(.reminders).isEmpty)
        #expect(redo.undo == .setReminder(refs[0], dueAt: nine, condition: .always))
        _ = try f.store.undo(redo, origin: .app)
        #expect(try f.store.thread(refs[0])?.reminderAt == nine)
    }

    @Test func aSecondReminderReplacesTheFirstAndUndoRestoresIt() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        _ = try f.store.apply(.setReminder(refs[0], dueAt: nine, condition: .always), origin: .app)
        let replace = try f.store.apply(.setReminder(refs[0], dueAt: ten, condition: .ifNoReply), origin: .app)
        #expect(replace.undo == .setReminder(refs[0], dueAt: nine, condition: .always))
        #expect(try f.reminders("t1").map { $0["state"] as String } == ["cancelled", "active"])
        #expect(try f.store.thread(refs[0])?.reminderAt == ten)
        let tid = refs[0].rowID.rawValue
        #expect(throws: (any Error).self) {
            try f.store.write { db in
                try db.execute(sql: """
                    INSERT INTO reminders (reminder_id, tid, account_id, gmail_thread_id, set_at, due_at, condition, state)
                    VALUES ('dup', ?, ?, 't1', 0, 0, 'always', 'active')
                    """, arguments: [tid, f.account.rawValue])
            }
        }
        _ = try f.store.undo(replace, origin: .app)
        let active = try f.reminders("t1").filter { ($0["state"] as String) == "active" }
        #expect(active.count == 1 && active[0]["due_at"] as Int64 == epochMillis(nine) && active[0]["condition"] as String == "always")
        let same = try f.store.apply(.setReminder(refs[0], dueAt: nine, condition: .always), origin: .app)
        #expect(try same.operationIDs.isEmpty && same.undo == nil && f.reminders("t1").count == 3)
    }

    @Test func cancelUndoesToTheSameReminderAndCancellingNothingIsEmpty() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        #expect(try f.store.apply(.cancelReminder(refs[0]), origin: .app) == ActionReceipt(operationIDs: []))
        _ = try f.store.apply(.setReminder(refs[0], dueAt: nine, condition: .ifNoReply), origin: .app)
        let cancel = try f.store.apply(.cancelReminder(refs[0]), origin: .app)
        #expect(cancel.undo == .setReminder(refs[0], dueAt: nine, condition: .ifNoReply))
        #expect(try f.store.thread(refs[0])?.reminderAt == nil)
        _ = try f.store.undo(cancel, origin: .app)
        #expect(try f.store.thread(refs[0])?.reminderAt == nine)
        let ghost = ThreadRef(accountID: f.account, rowID: ThreadRowID(rawValue: 999), gmailThreadID: GmailThreadID("x"))
        #expect(throws: StoreError.notFound("thread 999")) {
            try f.store.apply(.setReminder(ghost, dueAt: nine, condition: .always), origin: .app)
        }
    }

    @Test func firingAnAlwaysReminderQueuesOneInboxOpAndBoosts() throws {
        let f = try MutationFixture()
        let refs = try f.seed(2)
        _ = try f.store.apply(.archive([refs[0]]), origin: .app)
        try f.drain()
        _ = try f.store.apply(.setReminder(refs[0], dueAt: nine, condition: .always), origin: .app)
        let id = try #require(try f.store.activeReminders(account: f.account, limit: 10).first?.reminder.id)
        let fireAt = Date()
        let receipt = try #require(try f.store.fireReminder(id, now: fireAt, satisfied: false))
        #expect(receipt.operationIDs.count == 1 && receipt.undo == nil)
        let op = try f.op(receipt.operationIDs[0])
        #expect(op.origin == .scheduler && op.coalesceKey == nil && op.notBefore == MailStore.storeDate(millis: epochMillis(fireAt)))
        #expect(op.payload == .modifyLabels(ids: [GmailMessageID("m1")], add: [GmailLabelID("INBOX")], remove: [], addNames: []))
        #expect(try f.reminders("t1").map { $0["state"] as String } == ["fired"])
        #expect(try f.inbox().first == "t1")
        #expect(try f.threadRow("t1")["sort_boost_at"] as Int64? == epochMillis(fireAt))
        #expect(try f.store.thread(refs[0])?.reminderAt == nil && f.view(.reminders).isEmpty)
        #expect(try f.store.undo(receipt, origin: .app) == nil)
        #expect(try f.store.fireReminder(id, now: fireAt, satisfied: false) == nil)
        #expect(try f.store.fireReminder("unknown", now: fireAt, satisfied: false) == nil)
        #expect(try f.ops([.pending]).count == 1)
    }

    @Test func fireRulesForSatisfiedTrashedAndSnoozedThreads() throws {
        let f = try MutationFixture()
        try f.labels([("L_mark", "OpenHuman/Snoozed"), ("L_s9", snooze9)])
        try f.upsert([.fixture("a1", thread: "ta", labels: ["INBOX"]),
                      .fixture("b1", thread: "tb", labels: ["TRASH"]),
                      .fixture("c1", thread: "tc", labels: ["L_mark", "L_s9"])])
        for t in ["ta", "tb", "tc"] {
            _ = try f.store.apply(.setReminder(try f.ref(t), dueAt: nine, condition: .always), origin: .app)
        }
        let ids = Dictionary(uniqueKeysWithValues: try f.store.activeReminders(account: nil, limit: 10).map {
            ($0.ref.gmailThreadID.rawValue, $0.reminder.id)
        })
        let now = nine.addingTimeInterval(60)
        #expect(try f.store.fireReminder(try #require(ids["ta"]), now: now, satisfied: true) == nil)
        #expect(try f.store.fireReminder(try #require(ids["tb"]), now: now, satisfied: false) == nil)
        #expect(try f.store.fireReminder(try #require(ids["tc"]), now: now, satisfied: false) == nil)
        #expect(try f.reminders("ta").first?["state"] as String? == "satisfied")
        #expect(try f.reminders("tb").first?["state"] as String? == "cancelled")
        #expect(try f.reminders("tc").first?["state"] as String? == "fired")
        #expect(try f.ops().isEmpty)
        #expect(try f.snoozeRow("tc")?["status"] as String? == "active")
    }

    @Test func ifNoReplyIsSatisfiedByALaterMessageFromSomeoneElseOnly() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("m1", thread: "t1", minutes: 1, labels: ["SENT"], from: "me@example.com", to: ["bob@example.com"])])
        let t1 = try f.ref("t1")
        _ = try f.store.apply(.setReminder(t1, dueAt: nine, condition: .ifNoReply), origin: .app)
        let id = try #require(try f.store.activeReminders(account: f.account, limit: 10).first?.reminder.id)
        #expect(try f.store.hasReplySince(t1, anchor: nil) == false)
        try f.upsert([.fixture("m2", thread: "t1", minutes: 2, labels: ["SENT"], from: "me@example.com"),
                      .fixture("m3", thread: "t1", minutes: 3, labels: ["DRAFT"], from: "bob@example.com"),
                      .fixture("m4", thread: "t1", minutes: 4, labels: ["TRASH"], from: "bob@example.com")])
        #expect(try f.store.hasReplySince(t1, anchor: nil) == false)
        #expect(try f.store.hasReplySince(t1, anchor: GmailMessageID("m1")) == false)
        try f.upsert([.fixture("m5", thread: "t1", minutes: 5, labels: ["INBOX", "UNREAD"], from: "bob@example.com")])
        #expect(try f.store.hasReplySince(t1, anchor: nil) == true)
        #expect(try f.store.hasReplySince(t1, anchor: GmailMessageID("m5")) == false)
        #expect(try f.store.hasReplySince(t1, anchor: GmailMessageID("gone")) == false)
        #expect(try f.store.fireReminder(id, now: nine, satisfied: false) == nil)
        #expect(try f.reminders("t1").first?["state"] as String? == "satisfied")
        #expect(try f.ops().isEmpty && f.store.activeReminders(account: nil, limit: 10).isEmpty)
    }

    @Test func markingDoneDoesNotCancelAPendingReminderAndItBringsTheThreadBack() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        _ = try f.store.apply(.setReminder(refs[0], dueAt: nine, condition: .ifNoReply), origin: .app)
        _ = try f.store.apply(.archive(refs), origin: .app)
        try f.drain()
        #expect(try f.inbox().isEmpty && f.view(.reminders) == ["t1"])
        let due = try f.store.dueItems(account: f.account, now: nine)
        #expect(due.remindersDue.map(\.1.dueAt) == [nine])
        _ = try f.store.fireReminder(due.remindersDue[0].1.id, now: nine, satisfied: false)
        try f.drain(now: nine.addingTimeInterval(1))
        #expect(try f.inbox() == ["t1"] && f.server("m1").contains("INBOX"))
    }

    @Test func catchUpAfterSleepListsEveryMissedReminderWithItsDueTime() throws {
        let f = try MutationFixture()
        let refs = try f.seed(3)
        _ = try f.store.apply(.setReminder(refs[0], dueAt: nine, condition: .always), origin: .app)
        _ = try f.store.apply(.setReminder(refs[1], dueAt: ten, condition: .always), origin: .app)
        _ = try f.store.apply(.setReminder(refs[2], dueAt: ten.addingTimeInterval(86_400), condition: .always), origin: .app)
        #expect(try f.store.dueItems(account: f.account, now: nine.addingTimeInterval(-1)).remindersDue.isEmpty)
        #expect(try f.store.nextDueTime(account: f.account, kinds: [.reminder]) == nine)
        #expect(try f.store.nextDueTime(account: f.account, kinds: [.snooze, .sendLater]) == nil)
        let wake = nine.addingTimeInterval(4 * 3600)
        let due = try f.store.dueItems(account: f.account, now: wake).remindersDue
        #expect(due.map(\.0.gmailThreadID.rawValue) == ["t1", "t2"] && due.map(\.1.dueAt) == [nine, ten])
        #expect(due.map { wake.timeIntervalSince($0.1.dueAt) } == [4 * 3600, 3 * 3600])
        for item in due { _ = try f.store.fireReminder(item.1.id, now: wake, satisfied: false) }
        #expect(try f.store.dueItems(account: f.account, now: wake).remindersDue.isEmpty)
        #expect(try f.store.nextDueTime(account: f.account, kinds: [.reminder]) == ten.addingTimeInterval(86_400))
        #expect(try f.reminders("t1").first?["due_at"] as Int64? == epochMillis(nine))
    }

    @Test func activeRemindersFeedTheNotificationMirrorSoonestFirstPerAccount() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("m1", thread: "t1", minutes: 1, subject: "Later one"),
                      .fixture("m2", thread: "t2", minutes: 2, subject: "Sooner one")])
        let other = try f.store.addAccount(email: "other@example.com", displayName: nil, scopes: [])
        try f.store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: other, removeMissing: false)
        _ = try f.store.upsertMessages([.fixture("o1", thread: "o-t1", subject: "Other")], account: other, generation: 1)
        let otherRef = try #require(try f.store.thread(account: other, gmailThreadID: GmailThreadID("o-t1")))
        _ = try f.store.apply(.setReminder(try f.ref("t1"), dueAt: ten, condition: .always), origin: .app)
        _ = try f.store.apply(.setReminder(try f.ref("t2"), dueAt: nine, condition: .ifNoReply), origin: .app)
        _ = try f.store.apply(.setReminder(otherRef, dueAt: nine.addingTimeInterval(30), condition: .always), origin: .app)
        let mine = try f.store.activeReminders(account: f.account, limit: 10)
        #expect(mine.map(\.subject) == ["Sooner one", "Later one"])
        #expect(mine.map(\.reminder.condition) == [.ifNoReply, .always])
        #expect(try f.store.activeReminders(account: nil, limit: 10).map(\.subject) == ["Sooner one", "Other", "Later one"])
        #expect(try f.store.activeReminders(account: nil, limit: 1).count == 1)
    }

    @Test func historyIsKeptThirtyDaysAndThreadDeletionCascades() throws {
        let f = try MutationFixture()
        let refs = try f.seed(2)
        _ = try f.store.apply(.setReminder(refs[0], dueAt: nine, condition: .always), origin: .app)
        _ = try f.store.apply(.cancelReminder(refs[0]), origin: .app)
        _ = try f.store.apply(.setReminder(refs[0], dueAt: ten, condition: .always), origin: .app)
        let base = max(Date(), ten)
        try f.store.garbageCollectOperations(now: base.addingTimeInterval(29 * 86_400))
        #expect(try f.reminders("t1").count == 2)
        try f.store.garbageCollectOperations(now: base.addingTimeInterval(31 * 86_400))
        #expect(try f.reminders("t1").map { $0["state"] as String } == ["active"])
        _ = try f.store.apply(.setReminder(refs[1], dueAt: nine, condition: .always), origin: .app)
        _ = try f.store.deleteMessages([GmailMessageID("m2")], account: f.account, historyID: HistoryID(50))
        #expect(try f.raw("SELECT count(*) AS n FROM reminders WHERE gmail_thread_id = 't2'").first?["n"] as Int? == 0)
    }

    @Test func anyThreadMayGetAReminderIncludingTrashSpamAndDrafts() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("z1", thread: "tz", labels: ["TRASH"]), .fixture("s1", thread: "ts", labels: ["SPAM"])])
        for t in ["tz", "ts"] {
            let r = try f.store.apply(.setReminder(try f.ref(t), dueAt: nine, condition: .always), origin: .app)
            #expect(r.undo == .cancelReminder(try f.ref(t)))
        }
        #expect(try f.view(.trash) == ["tz"] && f.view(.spam) == ["ts"] && f.ops().isEmpty)
    }
}
