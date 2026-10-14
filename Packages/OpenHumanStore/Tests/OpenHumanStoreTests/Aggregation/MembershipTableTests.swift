import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

private func at(_ minutes: Int) -> Int64 { baseMillis + Int64(minutes) * 60_000 }

@Suite struct MembershipTableTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var messages: [(Int, [String])]
        var rows: [String: (Int, Bool)]
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "inbox, unread, category",
             messages: [(0, ["INBOX", "UNREAD", "CATEGORY_UPDATES"]), (5, ["INBOX"])],
             rows: ["INBOX": (5, true), "UNREAD": (5, true), "CATEGORY_UPDATES": (5, true), "oh:allmail": (5, true),
                    "oh:split:other": (5, true)]),
        Case(name: "starred and important outside the inbox",
             messages: [(0, ["STARRED"]), (9, ["IMPORTANT"])],
             rows: ["STARRED": (9, false), "IMPORTANT": (9, false), "oh:allmail": (9, false)]),
        Case(name: "sent sorts by its own messages", messages: [(0, ["SENT"]), (7, ["INBOX", "UNREAD"])],
             rows: ["SENT": (0, false), "INBOX": (7, true), "UNREAD": (7, true), "oh:allmail": (7, true),
                    "oh:split:other": (7, true)]),
        Case(name: "sent-only thread", messages: [(3, ["SENT"])], rows: ["SENT": (3, false), "oh:allmail": (3, false)]),
        Case(name: "draft-only thread", messages: [(4, ["DRAFT"])], rows: ["DRAFT": (4, false)]),
        Case(name: "draft beside mail", messages: [(1, ["INBOX"]), (6, ["DRAFT"])],
             rows: ["INBOX": (1, false), "DRAFT": (6, false), "oh:allmail": (1, false), "oh:split:other": (1, false)]),
        Case(name: "trash-only thread", messages: [(2, ["TRASH", "UNREAD"])], rows: ["TRASH": (2, true)]),
        Case(name: "spam-only thread", messages: [(2, ["SPAM", "INBOX"])], rows: ["SPAM": (2, false)]),
        Case(name: "partly trashed: other labels only from the rest",
             messages: [(1, ["INBOX"]), (8, ["TRASH", "STARRED", "UNREAD"])],
             rows: ["INBOX": (1, false), "TRASH": (8, true), "oh:allmail": (1, false), "oh:split:other": (1, false)]),
        Case(name: "user label", messages: [(2, ["Label_1", "UNREAD"])],
             rows: ["Label_1": (2, true), "UNREAD": (2, true), "oh:allmail": (2, true)]),
    ]

    @Test(arguments: cases) func rows(_ c: Case) throws {
        let f = try AggregationFixture()
        try f.labels([("Label_1", "Projects")])
        try f.upsert(c.messages.enumerated().map { i, m in .fixture("m\(i)", thread: "t", minutes: m.0, labels: m.1) })
        let t = try f.tid("t")
        let got = try f.store.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.key, tl.sort_at, tl.unread FROM thread_labels tl JOIN labels l USING (label_rid) WHERE tl.tid = ?
                """, arguments: [t])
        }
        var map: [String: (Int64, Bool)] = [:]
        for r in got { map[r["key"]] = (r["sort_at"], r["unread"]) }
        #expect(Set(map.keys) == Set(c.rows.keys))
        for (key, want) in c.rows {
            #expect(map[key]?.0 == at(want.0), "\(key) sort_at")
            #expect(map[key]?.1 == want.1, "\(key) unread")
        }
    }

    @Test func threadColumnsFollowTheVisibilityFallbacks() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("a", thread: "tr", minutes: 1, labels: ["TRASH"], subject: "Trashed", snippet: "gone"),
                      .fixture("b", thread: "tr", minutes: 2, labels: ["TRASH", "UNREAD"], snippet: "later")])
        var row = try f.threadRow("tr")
        #expect(row["is_trashed"] as Bool && row["message_count"] as Int == 2 && row["unread_count"] as Int == 1)
        #expect(row["snippet"] as String == "later" && row["subject"] as String == "Trashed")
        try f.upsert([.fixture("d", thread: "td", minutes: 1, labels: ["DRAFT"], subject: "Draft subject")])
        row = try f.threadRow("td")
        #expect(row["message_count"] as Int == 1 && row["draft_count"] as Int == 1 && row["subject"] as String == "Draft subject")
        #expect(!(row["is_trashed"] as Bool) && !(row["in_inbox"] as Bool))
    }

    @Test func remindersAndLocalDraftsMakeRowsAndKeepAThreadAlive() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "t1", minutes: 1, labels: ["INBOX", "UNREAD"])])
        let t1 = try f.tid("t1")
        let due = at(90)
        try f.mutate { db in
            try db.execute(sql: """
                INSERT INTO reminders (reminder_id, tid, account_id, gmail_thread_id, set_at, due_at, condition, state)
                VALUES ('r1', ?, ?, 't1', 0, ?, 'always', 'active')
                """, arguments: [t1, f.account.rawValue, due])
        }
        #expect(try f.sortKeys("t1")["oh:reminders"] == due)
        #expect(try f.store.thread(f.ref("t1"))?.reminderAt == Date(timeIntervalSince1970: Double(due) / 1000))
        #expect(try f.view(.system(f.account, .reminders)) == ["t1"])

        try f.mutate { db in
            try db.execute(sql: """
                INSERT INTO drafts (draft_uuid, account_id, tid, gmail_thread_id, compose_mode, subject, created_at, updated_at)
                VALUES ('local-1', ?, ?, 't1', 'reply', 'Re: Hello', 0, 0)
                """, arguments: [f.account.rawValue, t1])
        }
        #expect(try f.threadRow("t1")["draft_count"] as Int == 1)
        _ = try f.store.deleteMessages([GmailMessageID("m1")], account: f.account, historyID: HistoryID(5))
        let row = try f.threadRow("t1")
        #expect(row["message_count"] as Int == 0 && row["draft_count"] as Int == 1 && !(row["in_inbox"] as Bool))
        #expect(try f.keys("t1") == ["oh:reminders"])
        try f.mutate { db in try db.execute(sql: "UPDATE drafts SET state = 'discarded'") }
        #expect(try f.store.thread(account: f.account, gmailThreadID: GmailThreadID("t1")) == nil)
        #expect(try f.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM reminders") } == 0)
    }

    @Test func aGmailDraftBackedByALocalRowCountsOnce() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX"]),
                      .fixture("dm1", thread: "t1", minutes: 2, labels: ["DRAFT"], from: "me@example.com")])
        #expect(try f.threadRow("t1")["draft_count"] as Int == 1)
        try f.store.reconcileRemoteDrafts([f.remote("r1", message: "dm1", thread: "t1")], account: f.account, complete: true)
        #expect(try f.threadRow("t1")["draft_count"] as Int == 1)
    }
}
