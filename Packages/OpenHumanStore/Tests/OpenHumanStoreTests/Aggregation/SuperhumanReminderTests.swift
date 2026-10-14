import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

private let sender = "reminder@superhuman.com"

private func ms(_ minutes: Int) -> Int64 { baseMillis + Int64(minutes) * 60_000 }

private func reminder(_ id: String, thread: String, minutes: Int, labels: [String] = ["INBOX", "UNREAD"],
                      from: String = sender, inReplyTo: String? = nil) -> MessageUpsert {
    var m = MessageUpsert.fixture(id, thread: thread, minutes: minutes, labels: labels, from: from, fromName: "Reminders",
                                  subject: "Reminder", snippet: "reminder text")
    m.headers?.inReplyTo = inReplyTo
    return m
}

extension AggregationFixture {
    func setGlobal<T: Codable & Sendable>(_ name: String, _ value: T, default fallback: T) throws {
        try store.setSetting(SettingKey(name: name, defaultValue: fallback, isSafetyKey: false), value, scope: .global)
    }

    func setAccount<T: Codable & Sendable>(_ name: String, _ value: T, default fallback: T) throws {
        try store.setSetting(SettingKey(name: name, defaultValue: fallback, isSafetyKey: false), value, scope: .account(account))
    }

    func ruleStarts(atMinute minutes: Int) throws {
        try setGlobal("superhuman_reminders.since", Optional(ms(minutes)), default: Int64?.none)
    }

    func int(_ thread: String, _ column: String) throws -> Int64? { try threadRow(thread)[column] }

    func inboxCounts() throws -> (total: Int, unread: Int) {
        let inbox = try #require(try store.label(account: account, key: "INBOX"))
        return (inbox.totalThreads, inbox.unreadThreads)
    }

    func pendingOps() throws -> Int {
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pending_operations") ?? 0 }
    }
}

@Suite struct SuperhumanReminderTests {
    private func returnedConversation(_ f: AggregationFixture) throws {
        try f.upsert([
            .fixture("m1", thread: "t1", minutes: 1, labels: [], subject: "Plan", snippet: "the plan"),
            reminder("r1", thread: "t1", minutes: 50),
            .fixture("m2", thread: "t2", minutes: 30, labels: ["INBOX"], from: "bob@example.com", fromName: "Bob"),
        ])
    }

    @Test func aReminderEmailInItsConversationIsHiddenAndTheConversationComesBackOnTop() throws {
        let f = try AggregationFixture()
        try f.ruleStarts(atMinute: 0)
        try returnedConversation(f)
        #expect(try f.inbox() == ["t1", "t2"], "back on top at the reminder's time, like a wake")
        #expect(try f.int("t1", "message_count") == 1 && f.int("t1", "unread_count") == 0)
        #expect(try f.int("t1", "last_message_at") == ms(1) && f.int("t1", "sort_boost_at") == ms(50))
        let row = try f.threadRow("t1")
        #expect((row["snippet"] as String) == "the plan" && !(row["participants_display"] as String).contains("Reminders"))
        #expect(try !f.keys("t1").contains("UNREAD"))
        let counts = try f.inboxCounts()
        #expect(counts.total == 2 && counts.unread == 0, "no unread count, no Dock badge from the reminder email")
        let detail = try #require(try f.store.threadDetail(ThreadRowID(rawValue: f.tid("t1"))))
        #expect(detail.messages.count == 2, "sync still sees every message")
        #expect(detail.hiddenMessageIDs.count == 1)
        #expect(try f.pendingOps() == 0, "a local rule: nothing is queued for Gmail")
        try f.upsert([.fixture("m3", thread: "t1", minutes: 60, labels: ["INBOX", "UNREAD"], from: "carol@example.com")])
        #expect(try f.int("t1", "sort_boost_at") == nil && f.int("t1", "unread_count") == 1)
    }

    @Test func theBacklogWaitsForTheImportAndUndoShowsItAgain() throws {
        let f = try AggregationFixture()
        try f.ruleStarts(atMinute: 100)
        try returnedConversation(f)
        #expect(try f.int("t1", "message_count") == 2 && f.int("t1", "unread_count") == 1, "older than the rule: left alone")
        try f.setGlobal("superhuman_reminders.backlog_imported", true, default: false)
        #expect(try f.int("t1", "message_count") == 1 && f.int("t1", "unread_count") == 0)
        #expect(try f.int("t1", "sort_boost_at") == ms(50))
        try f.setGlobal("superhuman_reminders.backlog_imported", false, default: false)
        #expect(try f.int("t1", "message_count") == 2 && f.int("t1", "unread_count") == 1)
        #expect(try f.pendingOps() == 0)
    }

    @Test func turningTheRuleOffOrChangingTheSenderShowsThemAgain() throws {
        let f = try AggregationFixture()
        try f.ruleStarts(atMinute: 0)
        try returnedConversation(f)
        try f.setGlobal("superhuman_reminders.hide", false, default: true)
        #expect(try f.int("t1", "message_count") == 2 && f.int("t1", "unread_count") == 1)
        try f.setGlobal("superhuman_reminders.hide", true, default: true)
        #expect(try f.int("t1", "message_count") == 1)
        try f.setGlobal("superhuman_reminders.senders", ["someone-else@vendor.example"], default: [sender])
        #expect(try f.int("t1", "message_count") == 2, "the old sender's mail is derived again")
    }

    @Test func anEmailInAConversationOfItsOwnStaysVisibleWhenNothingMatches() throws {
        let f = try AggregationFixture()
        try f.ruleStarts(atMinute: 0)
        try f.upsert([reminder("r9", thread: "t9", minutes: 20)])
        #expect(try f.inbox() == ["t9"])
        let items = try f.store.superhumanReminderEmails(account: f.account, limit: 10)
        #expect(items.count == 1 && items[0].match == .unmatched && !items[0].isHidden && items[0].isInInbox)
    }

    @Test func anEmailOfItsOwnMatchedByReplyHeadersIsHiddenOnceConverted() throws {
        let f = try AggregationFixture()
        try f.ruleStarts(atMinute: 0)
        try f.upsert([
            .fixture("m1", thread: "t1", minutes: 1, labels: [], subject: "Plan"),
            reminder("r9", thread: "t9", minutes: 60, inReplyTo: "<m1@example.com>"),
        ])
        let item = try #require(try f.store.superhumanReminderEmails(account: f.account, limit: 10).first)
        let original = try f.ref("t1")
        #expect(item.match == .replyHeaders(target: original) && item.subject == "Plan" && !item.targetInInbox)
        #expect(try f.inbox() == ["t9"], "not converted yet: still visible")
        try f.setAccount("superhuman_reminders.returned", ["t1": ms(60)], default: [String: Int64]())
        try f.setAccount("superhuman_reminders.converted", ["r9"], default: [String]())
        #expect(try f.keys("t9").isEmpty && f.int("t9", "in_inbox") == 0, "listed nowhere")
        try f.op(["m1"], add: ["INBOX"])
        #expect(try f.inbox() == ["t1"])
        #expect(try f.int("t1", "sort_boost_at") == ms(60))
        let counts = try f.inboxCounts()
        #expect(counts.total == 1 && counts.unread == 0)
        #expect(try f.store.superhumanReminderEmails(account: f.account, limit: 10).first?.isHidden == true)
    }

    @Test func duplicatesAndResyncsNeverDuplicate() throws {
        let f = try AggregationFixture()
        try f.ruleStarts(atMinute: 0)
        let batch: [MessageUpsert] = [
            .fixture("m1", thread: "t1", minutes: 1, labels: []),
            reminder("r1", thread: "t1", minutes: 40),
            reminder("r2", thread: "t1", minutes: 45),
        ]
        try f.upsert(batch)
        try f.upsert(batch)
        #expect(try f.inbox() == ["t1"])
        #expect(try f.int("t1", "message_count") == 1 && f.int("t1", "sort_boost_at") == ms(45))
        let counts = try f.inboxCounts()
        #expect(counts.total == 1 && counts.unread == 0)
        #expect(try f.store.superhumanReminderEmails(account: f.account, limit: 10).map(\.isHidden) == [true, true])
    }

    @Test func onlyTheExactSenderAddressCountsAndNeverTheUsersOwnMail() throws {
        let f = try AggregationFixture()
        try f.ruleStarts(atMinute: 0)
        try f.setGlobal("superhuman_reminders.senders", [sender, "Reminders@SuperHuman.com", "me@example.com"],
                        default: [sender])
        var lookalike = reminder("x1", thread: "t1", minutes: 10, from: "someone@else.example")
        lookalike.headers?.from = EmailAddress(name: sender, email: "someone@else.example")
        try f.upsert([
            .fixture("m1", thread: "t1", minutes: 1, labels: []),
            lookalike,
            reminder("r1", thread: "t1", minutes: 20, from: "REMINDER@superhuman.com"),
            reminder("r2", thread: "t1", minutes: 30, from: "reminders@superhuman.com"),
            .fixture("mine", thread: "t1", minutes: 35, labels: ["SENT"], from: "me@example.com"),
        ])
        #expect(try f.int("t1", "message_count") == 3)
        #expect(try f.store.superhumanReminderEmails(account: f.account, limit: 10).count == 2)
    }
}
