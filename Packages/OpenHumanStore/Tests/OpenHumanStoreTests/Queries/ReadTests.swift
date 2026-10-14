import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct ReadTests {
    @Test func countsCoverLabelsInboxSplitsDraftsReviewAndFailedOps() throws {
        let f = try AggregationFixture()
        try f.upsert([
            .fixture("a", thread: "ta", minutes: 1, labels: ["INBOX", "UNREAD"]),
            .fixture("b", thread: "tb", minutes: 2, labels: ["INBOX", "UNREAD", "IMPORTANT"]),
            .fixture("c", thread: "tc", minutes: 3, labels: ["INBOX"]),
        ])
        let tid = try f.tid("ta")
        try f.store.insertDraft(account: f.account, tid: tid, gmailThread: "ta")
        try f.store.insertDraft(account: f.account, state: "failed")
        try f.store.insertDraft(account: f.account, state: "scheduled", review: "pending", origin: "agent")
        try f.store.insertDraft(account: f.account, state: "sent")
        try f.store.insertDraft(account: f.account, review: "pending", origin: "agent")
        try f.store.insertDraft(account: f.account, state: "discarded", review: "pending")
        try f.op(["a"], remove: ["INBOX"], status: "failed")
        try f.op(["c"], remove: ["INBOX"], status: "pending")

        let counts = try f.store.counts(account: f.account)
        #expect(counts.inboxUnread == 2)
        let inbox = try #require(try f.store.label(account: f.account, key: "INBOX"))
        #expect(counts.byLabel[inbox.id] == LabelCount(total: 2, unread: 2))
        #expect(counts.draftsCount == 3)
        #expect(counts.pendingReviewCount == 2)
        #expect(counts.failedOperationCount == 1)
        let important = try #require(try f.store.splits(account: f.account).first)
        let calendar = try #require(try f.store.splits(account: f.account).first { $0.name == "Calendar" })
        #expect(counts.splitUnread == [important.id: 1, calendar.id: 0])
    }

    @Test func countsOfOneAccountDoNotIncludeAnother() throws {
        let (store, a) = try OpenHumanStoreTesting.storeWithAccount()
        let b = try store.addAccount(email: "other@example.com", displayName: nil, scopes: [])
        try store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: b, removeMissing: false)
        _ = try store.upsertMessages([.fixture("x", labels: ["INBOX", "UNREAD"])], account: a, generation: 1)
        _ = try store.upsertMessages([.fixture("y1", labels: ["INBOX", "UNREAD"]), .fixture("y2", labels: ["INBOX", "UNREAD"])],
                                     account: b, generation: 1)
        try store.insertDraft(account: b)
        #expect(try store.counts(account: a).inboxUnread == 1)
        #expect(try store.counts(account: b).inboxUnread == 2)
        #expect(try store.counts(account: a).draftsCount == 0 && store.counts(account: b).draftsCount == 1)
    }

    @Test func splitsListTheSeededImportantSplitWithCounts() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("a", thread: "ta", labels: ["INBOX", "UNREAD", "IMPORTANT"]), .fixture("b", thread: "tb", labels: ["INBOX"])])
        let splits = try f.store.splits(account: f.account)
        #expect(splits.map(\.name) == ["Important", "Calendar"], "the seeded splits (7.6), in position order")
        let s = try #require(splits.first)
        #expect(s.name == "Important" && s.rule == .isImportant && s.enabled && s.ruleText == "is:important")
        #expect(s.totalThreads == 1 && s.unreadThreads == 1)
        let calendar = try #require(splits.last)
        #expect(calendar.rule == .isEvent && calendar.ruleText == "is:event" && calendar.totalThreads == 0)
        #expect(s.isImportanceSplit && !calendar.isImportanceSplit)
        #expect(try f.store.splits(account: AccountID(999)).isEmpty)
    }

    @Test func draftReadsFilterByAccountAndStateAndMapEveryColumn() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("a", thread: "ta")])
        let tid = try f.tid("ta")
        let id = try f.store.insertDraft(account: f.account, id: "d1", tid: tid, gmailThread: "ta", gmailDraft: "gd1",
                                         state: "editing", review: "pending", origin: "agent", subject: "Hello",
                                         updatedAt: 1_790_000_100_000, local: 3, synced: 2,
                                         conflict: "{\"x\":1}", note: "because")
        try f.store.insertDraft(account: f.account, id: "d2", state: "sent", updatedAt: 1_790_000_200_000)
        try f.store.insertDraft(account: f.account, id: "d3", state: "failed", updatedAt: 1_790_000_300_000)

        let d = try #require(try f.store.draft(id))
        #expect(d.accountID == f.account && d.gmailDraftID == GmailDraftID("gd1") && d.thread?.rowID.rawValue == tid)
        #expect(d.content.subject == "Hello" && d.content.to == [EmailAddress(name: "Bob", email: "bob@example.com")])
        #expect(d.content.from == EmailAddress(email: "me@example.com"))
        #expect(d.origin == .agent && d.reviewState == .pending && d.state == .editing)
        #expect(d.isDirty && d.hasRemoteConflict && d.agentNote == "because" && d.agentSnapshot == nil)
        #expect(d.updatedAt == Date(timeIntervalSince1970: 1_790_000_100))
        #expect(try f.store.draft(account: f.account, gmailDraftID: GmailDraftID("gd1"))?.id == id)
        #expect(try f.store.draft(account: f.account, gmailDraftID: GmailDraftID("nope")) == nil)
        #expect(try f.store.draft(DraftID("missing")) == nil)

        #expect(try f.store.drafts(account: f.account, states: [], limit: 10).map(\.id.rawValue) == ["d3", "d2", "d1"])
        #expect(try f.store.drafts(account: f.account, states: [.editing, .failed], limit: 10).map(\.id.rawValue) == ["d3", "d1"])
        #expect(try f.store.drafts(account: f.account, states: [], limit: 2).count == 2)
        #expect(try f.store.drafts(account: nil, states: [.sent], limit: 10).map(\.id.rawValue) == ["d2"])
        #expect(try f.store.drafts(account: AccountID(999), states: [], limit: 10).isEmpty)
        #expect(try f.store.reviewQueue(account: nil).map(\.id.rawValue) == ["d1"])
    }

    @Test func reviewQueueIsOldestFirstAndSkipsFinishedDrafts() throws {
        let f = try AggregationFixture()
        try f.store.insertDraft(account: f.account, id: "late", review: "pending", updatedAt: 3000)
        try f.store.insertDraft(account: f.account, id: "early", review: "pending", updatedAt: 1000)
        try f.store.insertDraft(account: f.account, id: "done", state: "sent", review: "pending", updatedAt: 2000)
        try f.store.insertDraft(account: f.account, id: "ok", review: "approved", updatedAt: 500)
        #expect(try f.store.reviewQueue(account: f.account).map(\.id.rawValue) == ["early", "late"])
    }

    @Test func threadDetailCarriesLiveDraftsSnoozeAndReminder() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("a", thread: "ta")])
        let tid = try f.tid("ta")
        try f.store.insertDraft(account: f.account, id: "live", tid: tid, gmailThread: "ta")
        try f.store.insertDraft(account: f.account, id: "sent", tid: tid, gmailThread: "ta", state: "sent")
        try f.store.write { db in
            try db.execute(sql: """
                INSERT INTO snoozes (tid, account_id, gmail_thread_id, wake_at, label_name, stamp_label_count, status)
                VALUES (?, ?, 'ta', 1790003600000, 'OpenHuman/Snoozed/20261012T0900Z', 2, 'active')
                """, arguments: [tid, f.account.rawValue])
            try db.execute(sql: """
                INSERT INTO reminders (reminder_id, tid, account_id, gmail_thread_id, set_at, due_at, condition, state)
                VALUES ('r1', ?1, ?2, 'ta', 1, 1790007200000, 'if_no_reply', 'active'),
                       ('r0', ?1, ?2, 'ta', 1, 1700000000000, 'always', 'cancelled')
                """, arguments: [tid, f.account.rawValue])
        }
        let detail = try #require(try f.store.threadDetail(ThreadRowID(rawValue: tid)))
        #expect(detail.drafts.map(\.id.rawValue) == ["live"])
        #expect(detail.snooze == SnoozeInfo(wakeAt: Date(timeIntervalSince1970: 1_790_003_600),
                                            labelName: "OpenHuman/Snoozed/20261012T0900Z", stampLabelCount: 2))
        #expect(detail.reminder == ReminderInfo(id: "r1", dueAt: Date(timeIntervalSince1970: 1_790_007_200), condition: .ifNoReply))
        let plain = try f.upsert([.fixture("z", thread: "tz")])
        let other = try #require(try f.store.threadDetail(try firstTid(plain)))
        #expect(other.drafts.isEmpty && other.snooze == nil && other.reminder == nil)
    }

    @Test func activeRemindersAreSoonestFirstWithSubjectAndAccountFilter() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("a", thread: "ta", subject: "Alpha"), .fixture("b", thread: "tb", subject: "Beta"),
                      .fixture("c", thread: "tc", subject: "Gamma")])
        let other = try f.store.addAccount(email: "o@example.com", displayName: nil, scopes: [])
        try f.store.write { db in
            for (id, thread, due, state) in [("r1", "ta", 3000, "active"), ("r2", "tb", 1000, "active"), ("r3", "tc", 2000, "fired")] {
                let tid = try Int64.fetchOne(db, sql: "SELECT tid FROM threads WHERE gmail_thread_id = ?", arguments: [thread])!
                try db.execute(sql: """
                    INSERT INTO reminders (reminder_id, tid, account_id, gmail_thread_id, set_at, due_at, condition, state)
                    VALUES (?, ?, ?, ?, 1, ?, 'always', ?)
                    """, arguments: [id, tid, f.account.rawValue, thread, due, state])
            }
        }
        let all = try f.store.read { try MailStore.reminderSummaries(account: nil, limit: 10, in: $0) }
        #expect(all.map(\.subject) == ["Beta", "Alpha"] && all.map(\.reminder.id) == ["r2", "r1"])
        #expect(all.first?.ref.gmailThreadID == GmailThreadID("tb"))
        #expect(try f.store.read { try MailStore.reminderSummaries(account: f.account, limit: 1, in: $0) }.count == 1)
        #expect(try f.store.read { try MailStore.reminderSummaries(account: other, limit: 10, in: $0) }.isEmpty)
    }

    @Test func snoozedViewListsWakeTimesOldestFirst() throws {
        let f = try AggregationFixture()
        try f.labels([("L1", "OpenHuman/Snoozed/20261012T0900Z"), ("L2", "OpenHuman/Snoozed/20261011T0900Z"),
                      ("L0", "OpenHuman/Snoozed")])
        try f.upsert([.fixture("a", thread: "ta", labels: ["L1", "L0"]), .fixture("b", thread: "tb", labels: ["L2", "L0"])])
        let snoozed = try f.store.threadPage(view: .system(f.account, .snoozed), after: nil, limit: 10).items
        #expect(snoozed.map(\.ref.gmailThreadID.rawValue) == ["tb", "ta"])
        #expect(snoozed.map(\.snoozedUntil) == [Date(timeIntervalSince1970: Double(millis("20261011T0900Z")) / 1000),
                                                Date(timeIntervalSince1970: Double(millis("20261012T0900Z")) / 1000)])
    }

    @Test func snippetsAreScopedToTheAccountPlusGlobalOnes() throws {
        let f = try AggregationFixture()
        let other = try f.store.addAccount(email: "o@example.com", displayName: nil, scopes: [])
        try f.store.write { db in
            for (id, account, name, shortcut) in [("s1", f.account.rawValue as Int64?, "Intro", "intro"), ("s2", nil, "bye", "bye"),
                                                   ("s3", other.rawValue as Int64?, "Other", "other")] {
                try db.execute(sql: """
                    INSERT INTO snippets (snippet_id, account_id, name, shortcut, body_html, variables_json, use_count, created_at, updated_at)
                    VALUES (?, ?, ?, ?, '<p>hi {{who}}</p>', '[{"name":"who","default":"there"}]', 4, 1, 1)
                    """, arguments: [id, account, name, shortcut])
            }
        }
        let mine = try f.store.snippets(account: f.account)
        #expect(mine.map(\.id) == ["s2", "s1"])
        #expect(mine.last?.variables == [SnippetVariable(name: "who", defaultValue: "there")] && mine.last?.useCount == 4)
        #expect(mine.last?.accountID == f.account && mine.first?.accountID == nil)
        #expect(try f.store.snippets(account: nil).count == 3)
    }

    @Test func contactSuggestionsMatchPrefixesAndOrderBySentThenReceived() throws {
        let f = try AggregationFixture()
        try f.store.write { db in
            let rows: [(String, String?, Int, Int)] = [
                ("alice@acme.example", "Alice Smith", 5, 1), ("al.bob@acme.example", "Bob Al", 1, 9), ("zed@acme.example", "Zed Alpha", 0, 3),
                ("100%@x.com", nil, 1, 0), ("under_score@x.com", nil, 1, 0), ("userscore@x.com", nil, 9, 0)]
            for (email, name, sent, received) in rows {
                try db.execute(sql: "INSERT INTO contacts (account_id, email, name, sent_count, received_count) VALUES (?, ?, ?, ?, ?)",
                               arguments: [f.account.rawValue, email, name, sent, received])
            }
        }
        func emails(_ prefix: String, limit: Int = 10) throws -> [String] {
            try f.store.contactSuggestions(account: f.account, prefix: prefix, limit: limit).map(\.email)
        }
        #expect(try emails("al") == ["alice@acme.example", "al.bob@acme.example", "zed@acme.example"])
        #expect(try emails("AL", limit: 2) == ["alice@acme.example", "al.bob@acme.example"])
        #expect(try emails("alp") == ["zed@acme.example"])
        #expect(try emails("smith") == ["alice@acme.example"])
        #expect(try emails("100%") == ["100%@x.com"])
        #expect(try emails("under_") == ["under_score@x.com"])
        #expect(try emails("").first == "userscore@x.com")
        #expect(try emails("nomatch").isEmpty)
        #expect(try f.store.contactSuggestions(account: AccountID(999), prefix: "al", limit: 5).isEmpty)
        let first = try #require(try f.store.contactSuggestions(account: f.account, prefix: "alice", limit: 1).first)
        #expect(first.name == "Alice Smith" && first.score > 5)
    }

    @Test func recentThreadsFindSendersAndSentRecipientsNewestFirst() throws {
        let f = try AggregationFixture()
        try f.upsert([
            .fixture("a1", thread: "ta", minutes: 1, from: "bob@example.com"),
            .fixture("b1", thread: "tb", minutes: 5, from: "bob@example.com"),
            .fixture("c1", thread: "tc", minutes: 3, labels: ["SENT"], from: "me@example.com", to: ["Bob@Example.com", "x@example.com"]),
            .fixture("d1", thread: "td", minutes: 9, labels: ["INBOX"], from: "carol@example.com", to: ["bob@example.com"]),
            .fixture("e1", thread: "te", minutes: 7, labels: ["TRASH"], from: "bob@example.com"),
            .fixture("f1", thread: "tf", minutes: 2, labels: ["SENT"], from: "me@example.com", to: ["bobby@example.com"]),
        ])
        let threads = try f.store.recentThreads(involving: "bob@example.com", account: f.account, limit: 10)
        #expect(threads.map(\.ref.gmailThreadID.rawValue) == ["tb", "tc", "ta"])
        #expect(try f.store.recentThreads(involving: "bob@example.com", account: f.account, limit: 2).count == 2)
        #expect(try f.store.recentThreads(involving: "", account: f.account, limit: 5).isEmpty)
        #expect(try f.store.recentThreads(involving: "100%_@example.com", account: f.account, limit: 5).isEmpty)
        #expect(try f.store.recentThreads(involving: "bob@example.com", account: AccountID(999), limit: 5).isEmpty)
    }

    @Test func attachmentLocalFileURLResolvesInsideTheStoreDirectoryOnly() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        try store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: account, removeMissing: false)
        _ = try store.upsertMessages([.fixture("m1")], account: account, generation: 1)
        try store.storeBodies([(GmailMessageID("m1"), .fixture(), [
            AttachmentUpsert(partID: "2", filename: "a.pdf", mimeType: "application/pdf", size: 10, isInline: false),
            AttachmentUpsert(partID: "3", filename: "b.pdf", mimeType: "application/pdf", size: 10, isInline: false),
            AttachmentUpsert(partID: "4", filename: "c.png", mimeType: "image/png", size: 10, contentID: "cid1", isInline: true)])],
            account: account)
        try store.write { db in
            try db.execute(sql: "UPDATE attachments SET local_path = 'Attachments/1/1/2/a.pdf' WHERE part_id = '2'")
            try db.execute(sql: "UPDATE attachments SET local_path = 'Attachments/../../etc/passwd' WHERE part_id = '3'")
            try db.execute(sql: "UPDATE attachments SET local_path = 'Attachments/1/1/4/c.png' WHERE part_id = '4'")
        }
        let mid = try store.read { try Int64.fetchOne($0, sql: "SELECT mid FROM messages")! }
        let atts = try store.attachments(message: MessageRowID(rawValue: mid))
        #expect(atts.map(\.partID) == ["2", "3", "4"])
        #expect(atts[0].localFileURL?.standardizedFileURL.path == dir.appendingPathComponent("Attachments/1/1/2/a.pdf").standardizedFileURL.path)
        #expect(atts[1].localFileURL == nil)
        let body = try #require(try store.body(MessageRowID(rawValue: mid)))
        #expect(body.inlineParts["cid1"]?.localFileURL != nil)
        try store.close()
    }

    @Test func syncStatusCountsQueueRowsAndReportsTheLease() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("a", thread: "ta"), .fixture("b", thread: "tb"), .fixture("c", thread: "tc")])
        try f.op(["a"], remove: ["INBOX"], status: "pending")
        try f.op(["b"], remove: ["INBOX"], status: "in_flight")
        try f.op(["c"], remove: ["INBOX"], status: "failed")
        try f.op(["c"], add: ["STARRED"], status: "succeeded")
        #expect(try f.store.syncStatus(account: f.account).owner == nil)
        _ = try f.store.acquireLease(account: f.account, ownerID: f.store.writerID, kind: "app", pid: ProcessInfo.processInfo.processIdentifier,
                                     host: ProcessIdentity.localHostName, now: Date(), ttl: .seconds(45))
        let status = try f.store.syncStatus(account: f.account)
        #expect(status.pendingOperations == 2 && status.failedOperations == 1)
        #expect(status.owner?.ownerID == f.store.writerID && status.owner?.isLive == true)
        #expect(throws: StoreError.notFound("sync_state 999")) { try f.store.syncStatus(account: AccountID(999)) }
    }

    @Test func syncLogIsNewestFirstAndLimited() throws {
        let f = try AggregationFixture()
        try f.store.write { db in
            for i in 0..<5 {
                try db.execute(sql: "INSERT INTO sync_log (account_id, started_at, kind, outcome, added) VALUES (?, ?, 'incremental', 'ok', ?)",
                               arguments: [f.account.rawValue, 1000 + i, i])
            }
        }
        let log = try f.store.syncLog(account: f.account, limit: 3)
        #expect(log.map(\.added) == [4, 3, 2])
        #expect(try f.store.syncLog(account: f.account, limit: 0).isEmpty)
    }

    @Test func liveWindowAllowsUpTo2000RowsButPagesStopAt500() throws {
        let (store, account) = try OpenHumanStoreTestingBridge.seeded(count: 700)
        #expect(try store.threadPage(view: .system(account, .inbox), after: nil, limit: 5000).items.count == 500)
        let window = try store.read { try MailStore.window(view: .system(account, .inbox), limit: 5000, in: $0) }
        #expect(window.items.count == 700 && !window.hasMore && window.totalCount == 700)
        let small = try store.read { try MailStore.window(view: .system(account, .inbox), limit: 600, in: $0) }
        #expect(small.items.count == 600 && small.hasMore)
    }

    @Test func keysetPagesSeeEveryOlderThreadOnceWhileNewMailArrivesAtTheTop() throws {
        let (store, account) = try OpenHumanStoreTestingBridge.seeded(count: 90)
        var seen: [Int64] = []
        var cursor: ThreadCursor?
        var inserted = 0
        repeat {
            let page = try store.threadPage(view: .system(account, .inbox), after: cursor, limit: 25)
            seen += page.items.map(\.id.rawValue)
            cursor = page.nextCursor
            _ = try store.upsertMessages([.fixture("new\(inserted)", minutes: 10_000 + inserted, labels: ["INBOX"])], account: account, generation: 1)
            inserted += 1
        } while cursor != nil
        let original = try store.read { try Int64.fetchAll($0, sql: "SELECT tid FROM threads WHERE gmail_thread_id LIKE 't-m%'") }
        #expect(Set(original).isSubset(of: Set(seen)))
        #expect(Set(seen).count == seen.count)
    }

    @Test func pageForAViewWithMissingLabelIsEmptyAndWindowTotalIsZero() throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let window = try store.read { try MailStore.window(view: .label(account, GmailLabelID("Label_9")), limit: 10, in: $0) }
        #expect(window == ThreadWindow(items: [], hasMore: false, totalCount: 0))
    }
}
