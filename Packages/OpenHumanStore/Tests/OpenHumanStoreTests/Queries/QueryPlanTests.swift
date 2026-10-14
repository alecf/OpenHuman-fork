import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct QueryPlanTests {
    private func corpus() throws -> (MailStore, SyntheticCorpus) {
        let store = try MailStore.openInMemoryForTesting()
        let corpus = try SyntheticCorpus.generate(.small, in: store)
        // No ANALYZE: without statistics SQLite assumes every table is large, matching the plan a big mailbox gets
        return (store, corpus)
    }

    @Test func theCorpusIsDeterministicAndHasTheRequestedShape() throws {
        let (a, ca) = try corpus()
        let (b, cb) = try corpus()
        #expect(ca.messageCount == 400 && ca.threadCount == 120 && ca.accounts.count == 2)
        #expect(ca.thirtyMessageThread != nil && !ca.messagesWithBody.isEmpty)
        func fingerprint(_ s: MailStore) throws -> [String] {
            try s.read { db in
                try Row.fetchAll(db, sql: "SELECT gmail_message_id, label_ids, internal_date, tid FROM messages ORDER BY gmail_message_id")
                    .map { "\($0["gmail_message_id"] as String)|\($0["label_ids"] as String)|\($0["internal_date"] as Int64)" }
            }
        }
        #expect(try fingerprint(a) == fingerprint(b))
        #expect(ca.senderAddresses == cb.senderAddresses)
        let counts = try a.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM messages")!, try Int.fetchOne(db, sql: "SELECT count(*) FROM threads")!,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM message_bodies")!)
        }
        #expect(counts.0 == 400 && counts.1 == 120 && counts.2 > 20 && counts.2 < 260)
        let inbox = try ca.accounts.map { try a.counts(account: $0).inboxUnread }
        #expect(inbox.allSatisfy { $0 >= 0 })
        let page = try a.threadPage(view: .system(ca.accounts[0], .inbox), after: nil, limit: 100)
        #expect(page.items.count == 15 && page.nextCursor == nil)
    }

    @Test func threadPagesUsePrimaryKeyRangesForEveryKindOfView() throws {
        let (store, c) = try corpus()
        let account = c.accounts[0]
        let label = try #require(c.userLabelIDs.first)
        for view in [MailboxView.system(account, .inbox), .system(account, .allMail), .system(account, .sent), .system(account, .trash),
                     .system(account, .snoozed), .system(account, .reminders), .label(account, label), .splitOther(account)] {
            let first = try store.threadPage(view: view, after: nil, limit: 10)
            let cursor = first.nextCursor ?? ThreadCursor(sortAt: 1_790_000_000_000, tid: 1_000_000)
            for after in [nil, cursor] {
                let result = try plans(store) { db in _ = try MailStore.page(view: view, after: after, limit: 50, in: db) }
                expectIndexed(result)
                let main = try #require(result.first { $0.sql.contains("FROM thread_labels") })
                #expect(main.plan.contains("SEARCH tl USING PRIMARY KEY"), "\(view)\n\(main.plan)")
                #expect(main.plan.contains("SEARCH t USING INTEGER PRIMARY KEY"), "\(view)\n\(main.plan)")
            }
        }
    }

    @Test func liveWindowAndLookupsAreIndexed() throws {
        let (store, c) = try corpus()
        let ref = try #require(try store.threadPage(view: .system(c.accounts[0], .allMail), after: nil, limit: 1).items.first?.ref)
        let account = c.accounts[0]
        expectIndexed(try plans(store) { db in _ = try MailStore.window(view: .system(account, .inbox), limit: 100, in: db) })
        expectIndexed(try plans(store) { db in _ = try MailStore.threadItem(tid: ref.rowID.rawValue, in: db) })
        expectIndexed(try plans(store) { db in
            _ = try Row.fetchOne(db, sql: "SELECT tid FROM threads WHERE account_id = ? AND gmail_thread_id = ?",
                                 arguments: [account.rawValue, ref.gmailThreadID.rawValue])
        })
    }

    @Test func threadDetailReadsMessagesAttachmentsAndDraftsByIndex() throws {
        let (store, c) = try corpus()
        let big = try #require(c.thirtyMessageThread)
        let ref = try #require(try store.thread(account: big.account, gmailThreadID: big.gmailThreadID))
        let dir = store.attachmentsDirectory
        let result = try plans(store) { db in _ = try MailStore.detail(ref.rowID, attachmentsDirectory: dir, in: db) }
        #expect(try store.threadDetail(ref.rowID)?.messages.count == 30)
        expectIndexed(result.filter { !$0.sql.contains("FROM drafts") })
        expectIndexed(result.filter { $0.sql.contains("FROM drafts") }, allowTempBTree: true)
        let messages = try #require(result.first { $0.sql.contains("FROM messages WHERE tid") })
        #expect(messages.plan.contains("messages_by_thread"), "\(messages.plan)")
        let attachments = try #require(result.first { $0.sql.contains("FROM attachments") })
        #expect(attachments.plan.contains("USING") && attachments.plan.contains("INDEX"), "\(attachments.plan)")
        let drafts = try #require(result.first { $0.sql.contains("FROM drafts") })
        #expect(drafts.plan.contains("drafts_by_thread"), "\(drafts.plan)")
    }

    @Test func bodyReadIsAPrimaryKeyLookup() throws {
        let (store, c) = try corpus()
        let probe = try #require(c.messagesWithBody.first)
        let message = try #require(try store.message(account: probe.account, gmailMessageID: probe.gmailMessageID))
        let dir = store.attachmentsDirectory
        let result = try plans(store) { db in _ = try MailStore.bodyItem(message.id, attachmentsDirectory: dir, in: db) }
        expectIndexed(result)
        #expect(result.first?.plan.contains("SEARCH message_bodies USING INTEGER PRIMARY KEY") == true, "\(result.first?.plan ?? "")")
    }

    @Test func countsNeverScanTheMailbox() throws {
        let (store, c) = try corpus()
        try store.insertDraft(account: c.accounts[0], review: "pending")
        let result = try plans(store) { db in _ = try MailStore.mailboxCounts(account: c.accounts[0], in: db) }
        expectIndexed(result)
        #expect(result.count >= 5)
        let drafts = try #require(result.first { $0.sql.contains("FROM drafts") })
        #expect(drafts.plan.contains("INDEX"), "\(drafts.plan)")
        let ops = try #require(result.first { $0.sql.contains("FROM pending_operations") })
        #expect(ops.plan.contains("INDEX"), "\(ops.plan)")
    }

    @Test func syncStatusAndLabelListsAreIndexed() throws {
        let (store, c) = try corpus()
        let account = c.accounts[0]
        expectIndexed(try plans(store) { db in _ = try MailStore.syncStatus(account: account, lease: nil, in: db) })
        expectIndexed(try plans(store) { db in _ = try MailStore.labelItems(account: account.rawValue, in: db) }, allowTempBTree: true)
        expectIndexed(try plans(store) { db in _ = try MailStore.splitItems(account: account.rawValue, in: db) }, allowTempBTree: true)
        expectIndexed(try plans(store) { db in _ = try MailStore.reminderSummaries(account: account, limit: 50, in: db) }, allowTempBTree: true)
    }

    @Test func contactAndRecentThreadReadsUseTheirIndexes() throws {
        let (store, c) = try corpus()
        let account = c.accounts[0]
        let sender = try #require(c.senderAddresses.first)
        let contacts = try plans(store) { db in
            _ = try Row.fetchAll(db, sql: "SELECT email FROM contacts WHERE account_id = ? AND email LIKE ? || '%' ESCAPE '\\'",
                                 arguments: [account.rawValue, "al"])
        }
        expectIndexed(contacts)
        #expect(try store.recentThreads(involving: sender, account: account, limit: 20).count <= 20)
        let fromSide = try queryPlan(store, """
            SELECT tid, internal_date FROM messages WHERE account_id = ?1 AND from_email = ?2 AND in_trash = 0 AND in_spam = 0
            AND is_draft = 0 ORDER BY internal_date DESC LIMIT 500
            """, [account.rawValue, sender])
        #expect(fromSide.contains("messages_by_from") && !fromSide.contains("TEMP B-TREE"), "\(fromSide)")
        let sentSide = try queryPlan(store, """
            SELECT tid FROM messages WHERE account_id = ?1 AND is_sent = 1 ORDER BY internal_date DESC LIMIT 2000
            """, [account.rawValue])
        #expect(sentSide.contains("messages_sent") && !sentSide.contains("TEMP B-TREE"), "\(sentSide)")
    }
}
