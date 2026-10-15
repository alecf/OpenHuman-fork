import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

private let yearThreeThousand = Date(timeIntervalSince1970: 32_503_680_000)

private extension MutationFixture {
    @discardableResult
    func fireAlways(_ thread: String, at now: Date) throws -> ActionReceipt? {
        _ = try store.apply(.setReminder(try ref(thread), dueAt: now, condition: .always), origin: .app)
        let id = try #require(try store.activeReminders(account: account, limit: 50)
            .first { $0.ref.gmailThreadID.rawValue == thread }?.reminder.id)
        return try store.fireReminder(id, now: now, satisfied: false)
    }

    func isReturned(_ thread: String) throws -> Bool {
        try #require(try store.thread(try ref(thread))).returnedByReminder
    }

    func recordedReturns() throws -> [String: Int64] {
        try store.read { try ReminderReturns.load(account: account.rawValue, in: $0) }
    }

    func archivedAndInbox() throws {
        try upsert([.fixture("m1", thread: "t1", minutes: 1, labels: []),
                    .fixture("m2", thread: "t2", minutes: 2, labels: ["INBOX", "UNREAD"])])
    }

    func snoozeLabels() throws {
        try labels([("L_mark", OHGmailLabels.snoozed), ("L_s9", snooze9), ("L_s10", snooze10)])
    }
}

@Suite struct ReminderReturnTests {
    @Test func aFiredReminderTagsTheThreadItReturns() throws {
        let f = try MutationFixture()
        try f.archivedAndInbox()
        #expect(try f.inbox() == ["t2"])
        let receipt = try f.fireAlways("t1", at: nine)
        #expect(receipt?.operationIDs.count == 1)
        #expect(try f.inbox() == ["t1", "t2"])
        #expect(try f.isReturned("t1") && !f.isReturned("t2"))
        #expect(try f.recordedReturns() == ["t1": epochMillis(nine)])
        #expect(try f.threadRow("t1")["sort_boost_at"] as Int64? == epochMillis(nine))
    }

    @Test func readingStarringAndLabellingKeepTheTag() throws {
        let f = try MutationFixture()
        try f.labels([("L_fin", "Finance")])
        try f.archivedAndInbox()
        try f.fireAlways("t1", at: nine)
        let t1 = try f.ref("t1")
        _ = try f.store.apply(.markRead([t1]), origin: .app)
        #expect(try f.isReturned("t1"))
        _ = try f.store.apply(.star([t1]), origin: .app)
        #expect(try f.isReturned("t1"))
        _ = try f.store.apply(.modifyLabels([t1], add: [GmailLabelID("L_fin")], remove: []), origin: .app)
        #expect(try f.isReturned("t1"))
        try f.drain()
        #expect(try f.isReturned("t1") && f.inbox().first == "t1")
    }

    @Test func archivingClearsTheTagAndUndoDoesNotBringItBack() throws {
        let f = try MutationFixture()
        try f.archivedAndInbox()
        try f.fireAlways("t1", at: nine)
        let done = try f.store.apply(.archive([try f.ref("t1")]), origin: .app)
        #expect(try !f.isReturned("t1") && f.inbox() == ["t2"])
        _ = try f.store.undo(done, origin: .app)
        #expect(try f.inbox().contains("t1"))
        #expect(try !f.isReturned("t1"))
    }

    @Test func newMailFromSomeoneElseOrMyOwnReplyClearsTheTag() throws {
        let f = try MutationFixture()
        try f.archivedAndInbox()
        try f.upsert([.fixture("m3", thread: "t3", minutes: 3, labels: [])])
        try f.fireAlways("t1", at: nine)
        try f.fireAlways("t3", at: nine)
        #expect(try f.isReturned("t1") && f.isReturned("t3"))
        try f.upsert([.fixture("m4", thread: "t1", minutes: 30_000, labels: ["INBOX", "UNREAD"], from: "bob@example.com")])
        #expect(try !f.isReturned("t1"))
        try f.upsert([.fixture("m5", thread: "t3", minutes: 30_000, labels: ["SENT"], from: "me@example.com",
                               to: ["bob@example.com"])])
        #expect(try !f.isReturned("t3"))
    }

    @Test func aSnoozeWakeIsNeverTaggedOrRecorded() throws {
        let f = try MutationFixture()
        try f.snoozeLabels()
        try f.upsert([.fixture("m1", thread: "t1", minutes: 1, labels: ["L_mark", "L_s9"])])
        _ = try f.store.wakeSnooze(try f.ref("t1"), confirmedLabels: [snooze9], messageIDs: [GmailMessageID("m1")], now: nine)
        #expect(try f.inbox() == ["t1"])
        #expect(try f.threadRow("t1")["sort_boost_at"] as Int64? == epochMillis(nine))
        #expect(try !f.isReturned("t1"))
        #expect(try f.recordedReturns().isEmpty)
    }

    @Test func aReturnedThreadThatIsSnoozedAndWokenIsNoLongerTagged() throws {
        let f = try MutationFixture()
        try f.snoozeLabels()
        try f.archivedAndInbox()
        try f.fireAlways("t1", at: nine)
        try f.drain()
        let t1 = try f.ref("t1")
        _ = try f.store.apply(.snooze([t1], until: ten), origin: .app)
        #expect(try !f.isReturned("t1"))
        try f.drain()
        _ = try f.store.wakeSnooze(t1, confirmedLabels: [snooze10], messageIDs: [GmailMessageID("m1")], now: ten)
        #expect(try f.inbox().first == "t1")
        #expect(try f.threadRow("t1")["sort_boost_at"] as Int64? == epochMillis(ten))
        #expect(try !f.isReturned("t1"))
    }

    @Test func wakingAReturnedThreadByHandIsNotTagged() throws {
        let f = try MutationFixture()
        try f.snoozeLabels()
        try f.archivedAndInbox()
        try f.fireAlways("t1", at: nine)
        try f.drain()
        let t1 = try f.ref("t1")
        _ = try f.store.apply(.snooze([t1], until: ten), origin: .app)
        try f.drain()
        _ = try f.store.apply(.unsnooze([t1]), origin: .app)
        #expect(try f.inbox().first == "t1")
        #expect(try !f.isReturned("t1"))
    }

    @Test func aReminderThatFiresWhileSnoozedLeavesTheWakeUntagged() throws {
        let f = try MutationFixture()
        try f.snoozeLabels()
        try f.upsert([.fixture("m1", thread: "t1", minutes: 1, labels: ["L_mark", "L_s9"])])
        #expect(try f.fireAlways("t1", at: nine) == nil)
        #expect(try f.reminders("t1").map { $0["state"] as String } == ["fired"])
        #expect(try f.recordedReturns().isEmpty && !f.isReturned("t1"))
        _ = try f.store.wakeSnooze(try f.ref("t1"), confirmedLabels: [snooze9], messageIDs: [GmailMessageID("m1")], now: nine)
        #expect(try f.threadRow("t1")["sort_boost_at"] as Int64? == epochMillis(nine))
        #expect(try !f.isReturned("t1"))
    }

    @Test func aThreadAlreadyInTheInboxIsTaggedWhenItsReminderFires() throws {
        let f = try MutationFixture()
        try f.seed(2)
        try f.fireAlways("t1", at: nine)
        #expect(try f.inbox() == ["t1", "t2"])
        #expect(try f.isReturned("t1") && !f.isReturned("t2"))
    }

    @Test func aNewReminderHidesTheTagUntilItIsUndone() throws {
        let f = try MutationFixture()
        try f.archivedAndInbox()
        try f.fireAlways("t1", at: nine)
        let again = try f.store.apply(.setReminder(try f.ref("t1"), dueAt: ten, condition: .always), origin: .app)
        #expect(try !f.isReturned("t1"))
        _ = try f.store.undo(again, origin: .app)
        #expect(try f.isReturned("t1"))
    }

    @Test func satisfiedAndCancelledRemindersReturnNothing() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("m1", thread: "t1", minutes: 1, labels: []),
                      .fixture("m2", thread: "t2", minutes: 2, labels: ["TRASH"])])
        for thread in ["t1", "t2"] {
            _ = try f.store.apply(.setReminder(try f.ref(thread), dueAt: nine, condition: .ifNoReply), origin: .app)
        }
        let ids = Dictionary(uniqueKeysWithValues: try f.store.activeReminders(account: f.account, limit: 10).map {
            ($0.ref.gmailThreadID.rawValue, $0.reminder.id)
        })
        #expect(try f.store.fireReminder(try #require(ids["t1"]), now: nine, satisfied: true) == nil)
        #expect(try f.store.fireReminder(try #require(ids["t2"]), now: nine, satisfied: false) == nil)
        #expect(try f.reminders("t1").first?["state"] as String? == "satisfied")
        #expect(try f.reminders("t2").first?["state"] as String? == "cancelled")
        #expect(try f.recordedReturns().isEmpty)
        #expect(try !f.isReturned("t1") && !f.isReturned("t2"))
    }

    @Test func eachFirePrunesEntriesThatNoLongerMatch() throws {
        let f = try MutationFixture()
        try f.archivedAndInbox()
        try f.fireAlways("t1", at: nine)
        _ = try f.store.apply(.archive([try f.ref("t1")]), origin: .app)
        try f.fireAlways("t2", at: ten)
        #expect(try f.recordedReturns() == ["t2": epochMillis(ten)])
        #expect(try f.isReturned("t2") && !f.isReturned("t1"))
    }

    @Test func theTagOutlivesTheFiredReminderRow() throws {
        let f = try MutationFixture()
        try f.archivedAndInbox()
        try f.fireAlways("t1", at: nine)
        try f.drain()
        try f.store.garbageCollectOperations(now: yearThreeThousand)
        #expect(try f.reminders("t1").isEmpty)
        #expect(try f.isReturned("t1"))
    }

    @Test func anUnreadableRecordReadsAsNoTagAndTheNextFireRewritesIt() throws {
        let f = try MutationFixture()
        try f.archivedAndInbox()
        try f.fireAlways("t1", at: nine)
        try f.store.write { db in
            try MailStore.upsertSetting(scope: .account(f.account), key: ReminderReturns.key, json: "{not json", in: db)
        }
        #expect(try !f.isReturned("t1"))
        #expect(try f.store.threadPage(view: .system(f.account, .inbox), after: nil, limit: 10).items.count == 2)
        try f.fireAlways("t2", at: ten)
        #expect(try f.recordedReturns() == ["t2": epochMillis(ten)])
        #expect(try f.isReturned("t2"))
    }

    @Test func theSameGmailThreadIDInAnotherAccountIsNotTagged() throws {
        let f = try MutationFixture()
        try f.archivedAndInbox()
        let other = try f.store.addAccount(email: "other@example.com", displayName: nil, scopes: [])
        try f.store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: other, removeMissing: false)
        _ = try f.store.upsertMessages([.fixture("o1", thread: "t1", minutes: 1, labels: ["INBOX"])], account: other,
                                       generation: 1)
        let otherRef = try #require(try f.store.thread(account: other, gmailThreadID: GmailThreadID("t1")))
        try f.store.write { db in
            try db.execute(sql: "UPDATE threads SET sort_boost_at = ? WHERE tid = ?",
                           arguments: [epochMillis(nine), otherRef.rowID.rawValue])
        }
        try f.fireAlways("t1", at: nine)
        #expect(try f.isReturned("t1"))
        #expect(try f.store.thread(otherRef)?.returnedByReminder == false)
    }

    @Test func everyReadPathCarriesTheTag() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("m1", thread: "t1", minutes: 1, labels: [], subject: "Budget review",
                               body: .fixture(html: nil, text: "numbers")),
                      .fixture("m2", thread: "t2", minutes: 2, labels: ["INBOX"], subject: "Lunch",
                               body: .fixture(html: nil, text: "noon"))])
        try f.fireAlways("t1", at: nine)
        let t1 = try f.ref("t1")
        _ = try f.store.apply(.star([t1]), origin: .app)
        let page = try f.store.threadPage(view: .system(f.account, .inbox), after: nil, limit: 10).items
        #expect(page.map(\.ref.gmailThreadID.rawValue) == ["t1", "t2"] && page.map(\.returnedByReminder) == [true, false])
        let window = try f.store.read { try MailStore.window(view: .system(f.account, .inbox), limit: 10, in: $0) }
        #expect(window.items.map(\.returnedByReminder) == [true, false])
        let starred = try f.store.threadPage(view: .system(f.account, .starred), after: nil, limit: 10).items
        #expect(starred.map(\.returnedByReminder) == [true])
        let hits = try f.store.search(try parseSearchQuery("budget"), accounts: [f.account], after: nil, limit: 10).hits
        #expect(hits.map(\.thread.ref.gmailThreadID.rawValue) == ["t1"] && hits.map(\.thread.returnedByReminder) == [true])
        #expect(try f.store.threadDetail(t1.rowID)?.thread.returnedByReminder == true)
        #expect(try f.store.thread(t1)?.returnedByReminder == true)
    }

    @Test func theTagSurvivesARestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        func open(_ kind: ProcessKind) throws -> MailStore {
            try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: kind,
                                            readOnly: false, appVersion: "0.0.0-test"))
        }
        let store = try open(.app)
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        try store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: account, removeMissing: false)
        _ = try store.upsertMessages([.fixture("m1", thread: "t1", minutes: 1, labels: [])], account: account, generation: 1)
        let ref = try #require(try store.thread(account: account, gmailThreadID: GmailThreadID("t1")))
        _ = try store.apply(.setReminder(ref, dueAt: nine, condition: .always), origin: .app)
        let id = try #require(try store.activeReminders(account: account, limit: 10).first?.reminder.id)
        _ = try store.fireReminder(id, now: nine, satisfied: false)
        #expect(try store.thread(ref)?.returnedByReminder == true)
        try store.close()
        let again = try open(.test)
        #expect(try again.thread(ref)?.returnedByReminder == true)
    }
}

private let reminderSender = "reminder@superhuman.com"

private func superhumanMillis(_ minutes: Int) -> Int64 { baseMillis + Int64(minutes) * 60_000 }

private func superhumanReminder(_ id: String, thread: String, minutes: Int,
                                labels: [String] = ["INBOX", "UNREAD"]) -> MessageUpsert {
    .fixture(id, thread: thread, minutes: minutes, labels: labels, from: reminderSender, fromName: "Reminders",
             subject: "Reminder", snippet: "reminder text")
}

private extension AggregationFixture {
    func isReturned(_ thread: String) throws -> Bool {
        try #require(try store.thread(try ref(thread))).returnedByReminder
    }
}

@Suite struct SuperhumanReminderReturnTests {
    @Test func aHiddenSuperhumanReminderEmailTagsItsConversationUntilNewMail() throws {
        let f = try AggregationFixture()
        try f.ruleStarts(atMinute: 0)
        try f.upsert([.fixture("m1", thread: "t1", minutes: 1, labels: [], subject: "Plan"),
                      superhumanReminder("r1", thread: "t1", minutes: 50),
                      .fixture("m2", thread: "t2", minutes: 30, labels: ["INBOX"], from: "bob@example.com")])
        #expect(try f.inbox() == ["t1", "t2"])
        #expect(try f.int("t1", "sort_boost_at") == superhumanMillis(50))
        #expect(try f.isReturned("t1") && !f.isReturned("t2"))
        try f.upsert([.fixture("m3", thread: "t1", minutes: 60, labels: ["INBOX", "UNREAD"], from: "carol@example.com")])
        #expect(try !f.isReturned("t1"))
    }

    @Test func anImportedReturnTagsTheConversation() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "t1", minutes: 1, labels: ["INBOX"]),
                      .fixture("m2", thread: "t2", minutes: 2, labels: ["INBOX"])])
        #expect(try !f.isReturned("t1"))
        try f.setAccount("superhuman_reminders.returned", ["t1": superhumanMillis(60)], default: [String: Int64]())
        #expect(try f.int("t1", "sort_boost_at") == superhumanMillis(60))
        #expect(try f.inbox() == ["t1", "t2"])
        #expect(try f.isReturned("t1") && !f.isReturned("t2"))
    }

    @Test func aSnoozeWakeIsNotASuperhumanReturnEvenWithAReminderEmailInTheThread() throws {
        let f = try AggregationFixture()
        try f.ruleStarts(atMinute: 0)
        try f.labels([("L_mark", OHGmailLabels.snoozed), ("L_s9", snooze9)])
        try f.upsert([.fixture("m1", thread: "t1", minutes: 1, labels: ["L_mark", "L_s9"]),
                      superhumanReminder("r1", thread: "t1", minutes: 50, labels: ["L_mark", "L_s9"]),
                      .fixture("m2", thread: "t2", minutes: 2, labels: ["L_mark", "L_s9"])])
        for (thread, mids) in [("t1", ["m1", "r1"]), ("t2", ["m2"])] {
            _ = try f.store.wakeSnooze(try f.ref(thread), confirmedLabels: [snooze9], messageIDs: mids.map { GmailMessageID($0) },
                                       now: nine)
        }
        #expect(try f.int("t1", "sort_boost_at") == epochMillis(nine))
        #expect(try f.int("t2", "sort_boost_at") == epochMillis(nine))
        #expect(try !f.isReturned("t1") && !f.isReturned("t2"))
    }
}
