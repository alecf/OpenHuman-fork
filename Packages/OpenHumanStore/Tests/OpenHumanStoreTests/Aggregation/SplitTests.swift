import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct SplitRuleSemanticsTests {
    private let context: AggregationContext = {
        let info: [AggregationContext.LabelInfo] = [
            .init(rid: 1, key: "Label_7", kind: "user", name: "Clients/Acme", hidden: false),
            .init(rid: 2, key: "Label_8", kind: "user", name: "OpenHuman/Snoozed", hidden: true),
            .init(rid: 3, key: "CATEGORY_PERSONAL", kind: "category", name: "CATEGORY_PERSONAL", hidden: false),
        ]
        return AggregationContext(account: 1, byKey: Dictionary(uniqueKeysWithValues: info.map { ($0.key, $0) }),
                                  ridByKey: [:], keyByName: [:], me: [], splits: [], otherSplitRid: nil)
    }()

    private func message(from: String = "alice@mail.acme.example", name: String? = "Alice Smith", to: [String] = ["me@x.com"],
                         labels: Set<String> = [], unread: Bool = false, attachments: Bool = false,
                         invite: Bool = false, list: String? = nil, subject: String = "Quarterly report") -> SplitFacts.Message {
        SplitFacts.Message(fromName: name, fromEmail: from, toJSON: WireAddress.encode(to.map { WireAddress(n: nil, e: $0) }),
                           ccJSON: "[]", labels: labels, isUnread: unread, isFromMe: false, hasAttachments: attachments,
                           hasCalendarInvite: invite, listID: list, subject: subject)
    }

    private func matches(_ rule: SplitRule, _ messages: [SplitFacts.Message]) -> Bool {
        SplitEvaluator.matches(rule, SplitFacts(messages: messages), LabelMatcher(context: context))
    }

    @Test func fromForms() {
        let m = [message()]
        #expect(matches(.from("ALICE@mail.acme.example"), m))
        #expect(!matches(.from("alice@acme.example"), m))
        #expect(matches(.from("@acme.example"), m) && matches(.from("acme.example"), m) && matches(.from("mail.acme.example"), m))
        #expect(!matches(.from("notacme.example"), [message(from: "x@notacme.org")]) && !matches(.from("acme.example"), [message(from: "x@notacme.example")]))
        #expect(matches(.from("smith"), m) && matches(.from("alice"), m) && !matches(.from("bob"), m))
        #expect(!matches(.from(""), m) && !matches(.from("@"), m))
    }

    @Test func toMatchesToAndCc() {
        var m = message(to: ["team@corp.example"])
        #expect(matches(.to("@corp.example"), [m]))
        m.toJSON = "[]"
        m.ccJSON = WireAddress.encode([WireAddress(n: "Ops", e: "ops@corp.example")])
        #expect(matches(.to("corp.example"), [m]) && matches(.to("ops"), [m]) && !matches(.to("alice"), [m]))
    }

    @Test func labelsByNameOrIdCaseInsensitiveButNeverHidden() {
        let m = [message(labels: ["Label_7", "Label_8"])]
        #expect(matches(.label("clients/acme"), m) && matches(.label("LABEL_7"), m))
        #expect(!matches(.label("OpenHuman/Snoozed"), m) && !matches(.label("Label_8"), m) && !matches(.label("nope"), m))
        #expect(matches(.category("primary"), [message(labels: ["CATEGORY_PERSONAL"])]))
        #expect(matches(.category("Promotions"), [message(labels: ["CATEGORY_PROMOTIONS"])]))
    }

    @Test func flagsAndText() {
        #expect(matches(.isImportant, [message(labels: ["IMPORTANT"])]) && !matches(.isImportant, [message()]))
        #expect(matches(.isStarred, [message(labels: ["STARRED"])]))
        #expect(matches(.isUnread, [message(), message(unread: true)]))
        #expect(matches(.hasAttachment, [message(attachments: true)]) && !matches(.hasAttachment, [message()]))
        #expect(matches(.hasCalendarInvite, [message(invite: true)]))
        #expect(matches(.list("Announce.Example"), [message(list: "<announce.example.org>")]))
        #expect(matches(.subjectContains("REPORT"), [message()]) && !matches(.subjectContains(""), [message()]))
        #expect(!matches(.fromMeOnly, [message()]))
    }

    @Test func booleanCombinators() {
        let m = [message(labels: ["IMPORTANT"])]
        #expect(matches(.and([.isImportant, .from("acme.example")]), m))
        #expect(!matches(.and([.isImportant, .isStarred]), m))
        #expect(matches(.or([.isStarred, .not(.isUnread)]), m))
        #expect(matches(.and([]), m) && !matches(.or([]), m))
    }
}

@Suite struct SplitEvaluationTests {
    @discardableResult
    private func setSplits(_ f: AggregationFixture, _ splits: [(String, Int, SplitRule, Bool)]) throws -> Int {
        try f.store.write { db in
            let a = f.account.rawValue
            let keep = splits.map { "oh:split:" + $0.0 } + ["oh:split:other"]
            let marks = Array(repeating: "?", count: keep.count).joined(separator: ", ")
            try db.execute(sql: "DELETE FROM labels WHERE account_id = ? AND kind = 'split' AND key NOT IN (\(marks))",
                           arguments: StatementArguments([a.databaseValue] + keep.map(\.databaseValue)))
            for (name, position, rule, enabled) in splits {
                let json = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
                if try Int.fetchOne(db, sql: "SELECT 1 FROM splits WHERE split_id = ?", arguments: [name]) != nil {
                    try db.execute(sql: "UPDATE splits SET position = ?, rule_json = ?, enabled = ? WHERE split_id = ?",
                                   arguments: [position, json, enabled, name])
                    continue
                }
                try db.execute(sql: """
                    INSERT INTO labels (account_id, key, kind, name, display_name, position, updated_at)
                    VALUES (?, ?, 'split', ?, ?, ?, 0)
                    """, arguments: [a, "oh:split:\(name)", name, name, position])
                try db.execute(sql: """
                    INSERT INTO splits (split_id, account_id, label_rid, name, position, rule_text, rule_json, enabled,
                                        created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, '', ?, ?, 0, 0)
                    """, arguments: [name, a, db.lastInsertedRowID, name, position, json, enabled])
            }
            return try ThreadAggregator.reevaluateSplits(account: a, in: db)
        }
    }

    private func split(_ f: AggregationFixture, _ thread: String) throws -> String {
        let keys = try f.keys(thread).filter { $0.hasPrefix("oh:split:") }
        try #require(keys.count <= 1, "a thread is in at most one split view")
        return keys.first.map { String($0.dropFirst("oh:split:".count)) } ?? "-"
    }

    @Test func theDefaultImportantSplitTakesImportantInboxThreads() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "imp", labels: ["INBOX", "IMPORTANT"]),
                      .fixture("m2", thread: "plain", labels: ["INBOX"]),
                      .fixture("m3", thread: "archived", labels: ["IMPORTANT"])])
        let important = try #require(try f.store.read { db in
            try String.fetchOne(db, sql: "SELECT split_id FROM splits WHERE account_id = ? AND role = 'important'",
                                arguments: [f.account.rawValue])
        })
        #expect(try f.view(.split(f.account, SplitID(important))) == ["imp"])
        #expect(try f.view(.splitOther(f.account)) == ["plain"])
        #expect(try split(f, "archived") == "-")
        #expect(try f.threadRow("imp")["split_rid"] as Int64? != nil && f.threadRow("plain")["split_rid"] as Int64? == nil)
    }

    @Test func firstMatchWinsAndDisabledSplitsAreSkipped() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "a", labels: ["INBOX", "IMPORTANT"], from: "ceo@acme.example"),
                      .fixture("m2", thread: "b", labels: ["INBOX"], from: "news@acme.example"),
                      .fixture("m3", thread: "c", labels: ["INBOX"], from: "x@other.org")])
        _ = try setSplits(f, [("vip", 0, .isImportant, true), ("acme", 1, .from("acme.example"), true),
                              ("off", 2, .from("other.org"), false)])
        #expect(try split(f, "a") == "vip" && split(f, "b") == "acme" && split(f, "c") == "other")
        _ = try setSplits(f, [("acme", 0, .from("acme.example"), true), ("vip", 1, .isImportant, true)])
        #expect(try split(f, "a") == "acme" && split(f, "b") == "acme" && split(f, "c") == "other")
        let splitOther = try #require(try f.store.label(account: f.account, key: "oh:split:other"))
        #expect(splitOther.totalThreads == 1)
    }

    @Test func aRuleChangeMovesThreadsAndKeepsCountsExact() throws {
        let f = try AggregationFixture()
        try f.upsert((0..<30).map { .fixture("m\($0)", thread: "t\($0)", minutes: $0, labels: $0 % 3 == 0 ? ["INBOX", "UNREAD"] : ["INBOX"],
                                             from: "p\($0 % 5)@example.com") })
        _ = try setSplits(f, [("p0", 0, .from("p0@example.com"), true)])
        #expect(try f.view(.split(f.account, SplitID("p0"))).count == 6)
        _ = try setSplits(f, [("p0", 0, .or([.from("p0@example.com"), .isUnread]), true)])
        let p0 = try #require(try f.store.label(account: f.account, key: "oh:split:p0"))
        #expect(p0.totalThreads == 14 && p0.unreadThreads == 10)
        let other = try #require(try f.store.label(account: f.account, key: "oh:split:other"))
        #expect(other.totalThreads == 16 && other.unreadThreads == 0)
        let pages = try f.view(.split(f.account, SplitID("p0")))
        #expect(pages.first == "t27")
        let snapshot = try self.snapshot(f)
        try f.mutate { _ in }
        #expect(try self.snapshot(f) == snapshot)
    }

    private func snapshot(_ f: AggregationFixture) throws -> [String] {
        try f.store.read { db in
            try String.fetchAll(db, sql: """
                SELECT tl.label_rid || ':' || tl.sort_at || ':' || tl.tid || ':' || tl.unread FROM thread_labels tl
                UNION ALL SELECT 'split:' || tid || ':' || ifnull(split_rid, '-') FROM threads
                UNION ALL SELECT 'count:' || label_rid || ':' || total_threads || ':' || unread_threads FROM labels
                ORDER BY 1
                """)
        }
    }

    @Test func threadsLeavingTheInboxLeaveTheirSplitAndNewMailIsEvaluated() throws {
        let f = try AggregationFixture()
        _ = try setSplits(f, [("acme", 0, .from("acme.example"), true)])
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX"], from: "a@acme.example", history: 1)])
        #expect(try split(f, "t1") == "acme")
        try f.upsert([.fixture("m1", thread: "t1", labels: [], from: "a@acme.example", history: 2)])
        #expect(try split(f, "t1") == "-" && f.threadRow("t1")["split_rid"] as Int64? == nil)
        try f.upsert([.fixture("m2", thread: "t1", minutes: 5, labels: ["INBOX"], from: "b@else.org", history: 3)])
        #expect(try split(f, "t1") == "acme")
    }
}
