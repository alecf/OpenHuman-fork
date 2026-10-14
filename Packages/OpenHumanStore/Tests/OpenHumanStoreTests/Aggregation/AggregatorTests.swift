import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

private func setup() throws -> (MailStore, AccountID) { try OpenHumanStoreTesting.storeWithAccount() }

private func keys(of store: MailStore, tid: ThreadRowID) throws -> Set<String> {
    Set(try store.read { db in
        try String.fetchAll(db, sql: """
            SELECT l.key FROM thread_labels tl JOIN labels l USING (label_rid) WHERE tl.tid = ?
            """, arguments: [tid.rawValue])
    })
}

@Suite struct AggregatorTests {
    @Test func inboxThreadRowAndMembership() throws {
        let (store, account) = try setup()
        let r = try store.upsertMessages([
            .fixture("m1", thread: "t1", minutes: 0, labels: ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], subject: "Plan",
                     snippet: "it&#39;s on"),
            .fixture("m2", thread: "t1", minutes: 5, labels: ["INBOX", "STARRED"], from: "bob@example.com", fromName: "Bob Jones"),
        ], account: account, generation: 1)
        #expect(r.inserted == 2 && r.touchedThreads.count == 1)
        let tid = try firstTid(r)
        let item = try detailOf(store, tid).thread
        #expect(item.subject == "Plan")
        #expect(item.messageCount == 2 && item.unreadCount == 1 && item.isStarred)
        #expect(item.participantsDisplay == "Bob, Alice (2)")
        #expect(item.snippet == "snippet")
        let k = try keys(of: store, tid: tid)
        #expect(k == ["INBOX", "UNREAD", "STARRED", "CATEGORY_PERSONAL", "oh:allmail", "oh:split:other"])
        let inbox = try #require(try store.label(account: account, key: "INBOX"))
        #expect(inbox.totalThreads == 1 && inbox.unreadThreads == 1)
        let page = try store.threadPage(view: .system(account, .inbox), after: nil, limit: 10)
        #expect(page.items.first?.sortAt == item.lastMessageAt)
    }

    @Test func snippetEntitiesAreDecoded() throws {
        let (store, account) = try setup()
        let r = try store.upsertMessages([.fixture("m1", snippet: "it&#39;s &amp; done")], account: account, generation: 1)
        let item = try detailOf(store, r).thread
        #expect(item.snippet == "it's & done")
    }

    @Test func archiveLeavesInboxButStaysInAllMail() throws {
        let (store, account) = try setup()
        _ = try store.upsertMessages([.fixture("m1", thread: "t1", labels: ["INBOX"])], account: account, generation: 1)
        let r = try store.upsertMessages([.fixture("m1", thread: "t1", labels: [], history: 2)], account: account, generation: 1)
        let tid = try firstTid(r)
        #expect(try keys(of: store, tid: tid) == ["oh:allmail"])
        #expect(try store.label(account: account, key: "INBOX")?.totalThreads == 0)
    }

    @Test func trashOnlyThread() throws {
        let (store, account) = try setup()
        let r = try store.upsertMessages([.fixture("m1", labels: ["TRASH"])], account: account, generation: 1)
        let tid = try firstTid(r)
        #expect(try keys(of: store, tid: tid) == ["TRASH"])
        let row = try store.read { try Row.fetchOne($0, sql: "SELECT is_trashed, in_inbox, message_count FROM threads")! }
        #expect(row["is_trashed"] as Bool && !(row["in_inbox"] as Bool))
        #expect(row["message_count"] as Int == 1)
    }

    @Test func draftOnlyAndSentOnlyThreads() throws {
        let (store, account) = try setup()
        let d = try store.upsertMessages([.fixture("d1", thread: "td", labels: ["DRAFT"], from: "me@example.com", fromName: nil)],
                                         account: account, generation: 1)
        #expect(try keys(of: store, tid: try firstTid(d)) == ["DRAFT"])
        let s = try store.upsertMessages([.fixture("s1", thread: "ts", labels: ["SENT"], from: "me@example.com", fromName: nil,
                                                   to: ["bob@example.com"])], account: account, generation: 1)
        let tid = try firstTid(s)
        #expect(try keys(of: store, tid: tid) == ["SENT", "oh:allmail", "oh:waiting"])
        let item = try detailOf(store, tid).thread
        #expect(item.participantsDisplay == "To: bob")
        let draftThread = try store.read { try Int.fetchOne($0, sql: "SELECT draft_count FROM threads WHERE gmail_thread_id = 'td'")! }
        #expect(draftThread == 1)
    }

    @Test func participantsRules() throws {
        let (store, account) = try setup()
        let msgs: [MessageUpsert] = [
            .fixture("a", thread: "t", minutes: 0, from: "a@x.com", fromName: "Ann Lee"),
            .fixture("b", thread: "t", minutes: 1, from: "b@x.com", fromName: nil),
            .fixture("c", thread: "t", minutes: 2, labels: ["SENT"], from: "me@example.com", fromName: "Me"),
            .fixture("d", thread: "t", minutes: 3, from: "d@x.com", fromName: "Dee"),
            .fixture("e", thread: "t", minutes: 4, from: "A@X.com", fromName: "Ann"),
        ]
        let r = try store.upsertMessages(msgs, account: account, generation: 1)
        let item = try detailOf(store, r).thread
        #expect(item.participantsDisplay == "Ann, Dee, b (5)")
        #expect(item.participants.count == 4)
        #expect(item.participants.first { $0.email == "me@example.com" }?.isMe == true)
    }

    @Test func staleWriteAndTombstone() throws {
        let (store, account) = try setup()
        _ = try store.upsertMessages([.fixture("m1", labels: ["INBOX"], history: 10)], account: account, generation: 1)
        let stale = try store.upsertMessages([.fixture("m1", labels: [], history: 5)], account: account, generation: 1)
        #expect(stale.skippedStale == 1)
        #expect(try store.message(account: account, gmailMessageID: GmailMessageID("m1"))?.labelIDs == [GmailLabelID("INBOX")])
        try store.write { db in
            try db.execute(sql: "INSERT INTO deleted_messages VALUES (?, 'gone', 50, 0)", arguments: [account.rawValue])
        }
        let t = try store.upsertMessages([.fixture("gone", history: 40)], account: account, generation: 1)
        #expect(t.skippedTombstoned == 1 && t.inserted == 0)
    }

    @Test func labelsArrivingAfterMessagesRepairMembership() throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let r = try store.upsertMessages([.fixture("m1")], account: account, generation: 1)
        #expect(r.unknownLabelIDs == [GmailLabelID("INBOX")])
        try store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: account, removeMissing: false)
        #expect(try store.label(account: account, key: "INBOX")?.totalThreads == 1)
    }

    @Test func userLabelsAndHiddenScheduleLabels() throws {
        let (store, account) = try setup()
        try store.upsertLabels([
            LabelUpsert(gmailLabelID: GmailLabelID("Label_1"), name: "Clients/Acme", type: "user"),
            LabelUpsert(gmailLabelID: GmailLabelID("Label_2"), name: "OpenHuman/Snoozed/20261012T0900Z", type: "user"),
        ], account: account, removeMissing: false)
        let r = try store.upsertMessages([.fixture("m1", labels: ["INBOX", "Label_1", "Label_2"])], account: account, generation: 1)
        let item = try detailOf(store, r)
        #expect(item.labels.map(\.displayName) == ["Acme"])
        #expect(try store.label(account: account, key: "Label_2")?.isHidden == true)
        let order = try store.labels(account: account).map(\.kind)
        #expect(order == order.sorted { $0.rank < $1.rank })
    }

    @Test func bodiesStoreAndFlagState() throws {
        let (store, account) = try setup()
        let r = try store.upsertMessages([.fixture("m1")], account: account, generation: 1)
        #expect(try store.messagesNeedingBodies(account: account, newerThan: .distantPast, limit: 10) == [GmailMessageID("m1")])
        try store.storeBodies([(GmailMessageID("m1"), .fixture(html: "<img src=\"https://x.test/a.png\">"), [])], account: account)
        let detail = try detailOf(store, r)
        let m = try #require(detail.messages.first)
        #expect(m.bodyState == .stored)
        let body = try #require(try store.body(m.id))
        #expect(body.hasRemoteContent && body.text == "Hi")
        #expect(try store.messagesNeedingBodies(account: account, newerThan: .distantPast, limit: 10).isEmpty)
        try store.markBodyFailed(GmailMessageID("m1"), account: account, reason: "x")
        #expect(try store.message(account: account, gmailMessageID: GmailMessageID("m1"))?.bodyState == .stored)
        _ = try store.upsertMessages([.fixture("m2")], account: account, generation: 1)
        try store.markBodyFailed(GmailMessageID("m2"), account: account, reason: "x")
        #expect(try store.message(account: account, gmailMessageID: GmailMessageID("m2"))?.bodyState == .failed)
        #expect(try store.messagesNeedingBodies(account: account, newerThan: .distantPast, limit: 10).isEmpty)
    }

    @Test func bodyCountsFollowBodyState() throws {
        let (store, account) = try setup()
        #expect(try store.bodyCounts(account: account) == BodyCounts())
        _ = try store.upsertMessages([.fixture("m1"), .fixture("m2"), .fixture("m3")], account: account, generation: 1)
        #expect(try store.bodyCounts(account: account) == BodyCounts(stored: 0, pending: 3, failed: 0))
        try store.storeBodies([(GmailMessageID("m1"), .fixture(html: "<p>a</p>"), [])], account: account)
        try store.markBodyFailed(GmailMessageID("m2"), account: account, reason: "x")
        #expect(try store.bodyCounts(account: account) == BodyCounts(stored: 1, pending: 1, failed: 1))
    }

    @Test func removeMissingLabelsAndKnownIDs() throws {
        let (store, account) = try setup()
        try store.upsertLabels([LabelUpsert(gmailLabelID: GmailLabelID("INBOX"), name: "INBOX", type: "system")],
                               account: account, removeMissing: true)
        #expect(try store.labels(account: account).filter { $0.kind == .system }.count == 1)
        _ = try store.upsertMessages([.fixture("m1")], account: account, generation: 1)
        #expect(try store.knownMessageIDs(account: account, among: [GmailMessageID("m1"), GmailMessageID("zz")]) == [GmailMessageID("m1")])
        let need = try store.threadsNeedingFetch(account: account, stubs: [(GmailThreadID("t-m1"), HistoryID(1)),
                                                                          (GmailThreadID("t-m1"), HistoryID(9)),
                                                                          (GmailThreadID("new"), HistoryID(1))])
        #expect(need == [GmailThreadID("t-m1"), GmailThreadID("new")])
    }

    @Test func countTriggersMatchRecountUnderRandomWrites() throws {
        let (store, account) = try setup()
        var rng = SplitMix(seed: 42)
        let pools: [[String]] = [["INBOX"], ["INBOX", "UNREAD"], [], ["SENT"], ["TRASH"], ["INBOX", "STARRED", "UNREAD"],
                                 ["SPAM"], ["DRAFT"], ["INBOX", "IMPORTANT"]]
        var history: [String: UInt64] = [:]
        for step in 0..<1000 {
            let mid = "m\(Int(rng.next() % 60))"
            let thread = "t\(Int(rng.next() % 25))"
            if rng.next() % 10 == 0 {
                try store.write { db in
                    try db.execute(sql: "DELETE FROM messages WHERE gmail_message_id = ?", arguments: [mid])
                    try ThreadAggregator.refresh(tids: Set(try Int64.fetchAll(db, sql: "SELECT tid FROM threads")), in: db)
                }
                history[mid] = nil
            } else {
                let h = (history[mid] ?? 0) + 1
                history[mid] = h
                let labels = pools[Int(rng.next() % UInt64(pools.count))]
                let existingThread = try store.message(account: account, gmailMessageID: GmailMessageID(mid)) == nil ? thread : nil
                var msg = MessageUpsert.fixture(mid, thread: existingThread ?? threadOf(store, account, mid) ?? thread,
                                                minutes: Int(rng.next() % 500), labels: labels, history: h)
                msg.internalDate = Date(timeIntervalSince1970: 1_790_000_000 + Double(rng.next() % 100_000))
                _ = try store.upsertMessages([msg], account: account, generation: 1)
            }
            if step % 50 == 0 || step == 999 { try assertCountsMatch(store) }
        }
    }
}

@Suite(.serialized) struct AggregatorConvergenceTests {
    @Test(arguments: (1...10).map { UInt64($0) }) func incrementalAggregationConvergesWithAFullRebuild(seed: UInt64) throws {
        let f = try AggregationFixture()
        let stamps = ["OpenHuman/Snoozed/20261012T0900Z", "OpenHuman/Snoozed/20261013T0900Z", "OpenHuman/Snoozed/bad"]
        var labelNames: [String: String] = ["L_mark": "OpenHuman/Snoozed", "L_s0": stamps[0], "L_s1": stamps[1],
                                            "L_s2": stamps[2], "Label_1": "Work", "Label_2": "Home"]
        try f.labels(labelNames.map { ($0.key, $0.value) })
        var rng = SplitMix(seed: seed)
        func pick<T>(_ list: [T]) -> T { list[Int(rng.next() % UInt64(list.count))] }
        let pools: [[String]] = [["INBOX"], ["INBOX", "UNREAD"], [], ["L_mark", "L_s0"], ["L_mark", "L_s1", "UNREAD"],
                                 ["L_s0", "L_s1"], ["L_mark"], ["L_s2"], ["TRASH", "L_s0"], ["DRAFT", "L_s1"],
                                 ["INBOX", "IMPORTANT", "Label_1"], ["SPAM"], ["SENT", "Label_2"], ["INBOX", "STARRED"]]
        var history: [String: UInt64] = [:]
        var threadOfMessage: [String: String] = [:]
        for step in 0..<400 {
            let mid = "m\(rng.next() % 40)"
            switch rng.next() % 9 {
            case 0, 1:
                let h = (history[mid] ?? 0) + 1
                history[mid] = h
                let thread = threadOfMessage[mid] ?? "t\(rng.next() % 12)"
                threadOfMessage[mid] = thread
                try f.upsert([.fixture(mid, thread: thread, minutes: Int(rng.next() % 300), labels: pick(pools),
                                       from: pick(["a@x.com", "b@y.org", "me@example.com"]), history: h)])
            case 2:
                guard let h = history[mid] else { continue }
                history[mid] = h + 1
                let label = pick(["INBOX", "UNREAD", "L_mark", "L_s0", "L_s1", "L_s2", "TRASH", "Label_1"])
                let add = rng.next() % 2 == 0
                _ = try f.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID(mid), historyID: HistoryID(h + 1),
                                                             added: add ? [GmailLabelID(label)] : [],
                                                             removed: add ? [] : [GmailLabelID(label)])], account: f.account)
            case 3:
                guard history[mid] != nil, rng.next() % 3 == 0 else { continue }
                history[mid] = nil
                threadOfMessage[mid] = nil
                _ = try f.store.deleteMessages([GmailMessageID(mid)], account: f.account, historyID: HistoryID(0))
            case 4:
                guard history[mid] != nil else { continue }
                if rng.next() % 2 == 0 {
                    try f.op([mid], add: ["L_mark", pick(["L_s0", "L_s1"])], remove: ["INBOX"])
                } else {
                    try f.op([mid], add: pick([["INBOX"], ["STARRED"]]), remove: ["L_mark", "L_s0", "L_s1"],
                             addNames: rng.next() % 3 == 0 ? ["OpenHuman/Snoozed/20261101T0700Z"] : [])
                }
            case 5:
                let ops = try f.store.operations(account: f.account, statuses: [.pending], limit: 50)
                guard !ops.isEmpty else { continue }
                let op = pick(ops)
                if rng.next() % 2 == 0 {
                    try f.store.fail(op.id, code: "x", message: "x", retryAt: nil)
                } else {
                    try f.store.complete(op.id, outcome: .labelsApplied)
                }
            case 6:
                let key = pick(["L_s0", "L_s1", "L_s2", "Label_1"])
                labelNames[key] = pick(stamps + ["OpenHuman/Snoozed/20261111T1111Z", "Renamed \(step)"])
                try f.labels(labelNames.map { ($0.key, $0.value) }, removeMissing: rng.next() % 5 == 0)
                if try f.store.label(account: f.account, key: key) == nil { labelNames[key] = nil }
            case 7:
                try f.mutate { db in
                    guard let tid = try Int64.fetchOne(db, sql: "SELECT tid FROM threads ORDER BY random() LIMIT 1") else { return }
                    try db.execute(sql: "UPDATE reminders SET state = 'cancelled' WHERE tid = ? AND state = 'active'", arguments: [tid])
                    if rng.next() % 2 == 0 {
                        try db.execute(sql: """
                            INSERT INTO reminders (reminder_id, tid, account_id, gmail_thread_id, set_at, due_at, condition, state)
                            SELECT ?, tid, account_id, gmail_thread_id, 0, ?, 'always', 'active' FROM threads WHERE tid = ?
                            """, arguments: ["r\(step)", Int64(rng.next() % 1_000_000), tid])
                    }
                }
            default:
                let rule = pick([SplitRule.isImportant, .from("x.com"), .or([.isUnread, .label("Work")]), .not(.isStarred)])
                try f.store.write { db in
                    try db.execute(sql: "UPDATE splits SET rule_json = ? WHERE account_id = ?",
                                   arguments: [String(decoding: try JSONEncoder().encode(rule), as: UTF8.self), f.account.rawValue])
                    try ThreadAggregator.reevaluateSplits(account: f.account.rawValue, in: db)
                }
            }
            if step % 25 == 24 {
                let incremental = try derivedState(f.store)
                try f.mutate { _ in }
                let rebuilt = try derivedState(f.store)
                #expect(rebuilt == incremental, """
                    step \(step): a full rebuild changed derived rows: \(Set(incremental).subtracting(rebuilt).sorted()) \
                    -> \(Set(rebuilt).subtracting(incremental).sorted())
                    """)
                try assertCountsMatch(f.store)
            }
        }
    }
}

private func derivedState(_ store: MailStore) throws -> [String] {
    try store.read { db in
        var out = try String.fetchAll(db, sql: "SELECT label_rid || ':' || sort_at || ':' || tid || ':' || unread FROM thread_labels")
        for row in try Row.fetchAll(db, sql: "SELECT * FROM threads") {
            out.append(row.columnNames.filter { $0 != "updated_at" }.map { "\($0)=\(row[$0] as DatabaseValue)" }.joined(separator: "|"))
        }
        out += try String.fetchAll(db, sql: """
            SELECT tid || ':' || ifnull(wake_at, '-') || ':' || ifnull(label_name, '-') || ':' || stamp_label_count || ':' || status
            FROM snoozes
            """)
        out += try String.fetchAll(db, sql: "SELECT mid || ':' || label_ids || ':' || is_unread || in_trash || in_spam FROM messages")
        return out.sorted()
    }
}

private func threadOf(_ store: MailStore, _ account: AccountID, _ mid: String) -> String? {
    try? store.read { db in
        try String.fetchOne(db, sql: """
            SELECT t.gmail_thread_id FROM messages m JOIN threads t USING (tid)
            WHERE m.account_id = ? AND m.gmail_message_id = ?
            """, arguments: [account.rawValue, mid])
    }
}

private func assertCountsMatch(_ store: MailStore) throws {
    let bad = try store.read { db in
        try Row.fetchAll(db, sql: """
            SELECT l.label_rid, l.total_threads, l.unread_threads,
                   COALESCE(c.n, 0) AS n, COALESCE(c.u, 0) AS u
            FROM labels l LEFT JOIN (SELECT label_rid, count(*) n, sum(unread) u FROM thread_labels GROUP BY label_rid) c
                 USING (label_rid)
            WHERE l.total_threads <> COALESCE(c.n, 0) OR l.unread_threads <> COALESCE(c.u, 0)
            """)
    }
    #expect(bad.isEmpty, "count drift: \(bad)")
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private extension LabelKind {
    var rank: Int { switch self { case .system: 0; case .category: 1; case .user: 2; case .virtual: 3; case .split: 4 } }
}
