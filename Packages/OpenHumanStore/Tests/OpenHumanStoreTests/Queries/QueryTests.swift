import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct QueryTests {
    private func seeded(count: Int) throws -> (MailStore, AccountID) {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        let msgs = (0..<count).map { i in
            MessageUpsert.fixture("m\(i)", minutes: i / 2, labels: ["INBOX"], subject: "S\(i)")
        }
        _ = try store.upsertMessages(msgs, account: account, generation: 1)
        return (store, account)
    }

    @Test func keysetPagesReturnEveryThreadOnceInOrder() throws {
        let (store, account) = try seeded(count: 120)
        var seen: [Int64] = []
        var cursor: ThreadCursor?
        var pages = 0
        repeat {
            let page = try store.threadPage(view: .system(account, .inbox), after: cursor, limit: 50)
            seen += page.items.map(\.id.rawValue)
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil
        #expect(pages == 3)
        #expect(seen.count == 120 && Set(seen).count == 120)
        let all = try store.threadPage(view: .system(account, .inbox), after: nil, limit: 500).items
        #expect(all.map(\.id.rawValue) == seen)
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.sortAt >= $1.sortAt })
    }

    @Test func pageMissingLabelAndUnifiedBehaviour() throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        #expect(try store.threadPage(view: .system(account, .inbox), after: nil, limit: 10).items.isEmpty)
        #expect(throws: StoreError.unsupportedView("unified")) {
            try store.threadPage(view: .unified(.inbox), after: nil, limit: 10)
        }
    }

    @Test func threadPageQueryPlanUsesPrimaryKeyWithoutTempBTree() throws {
        let (store, account) = try seeded(count: 20)
        let plan = try store.read { db -> String in
            let rid = try #require(try MailStore.resolve(.system(account, .inbox), in: db)).rid
            let rows = try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT \(MailStore.listColumns), tl.sort_at, tl.unread
                FROM thread_labels AS tl JOIN threads AS t ON t.tid = tl.tid
                WHERE tl.label_rid = ? AND (tl.sort_at, tl.tid) < (?, ?)
                ORDER BY tl.sort_at DESC, tl.tid DESC LIMIT 51
                """, arguments: [rid, 9_999_999_999_999, 99])
            return rows.map { $0["detail"] as String }.joined(separator: "\n")
        }
        #expect(plan.contains("SEARCH tl USING PRIMARY KEY"), "\(plan)")
        #expect(plan.contains("SEARCH t USING INTEGER PRIMARY KEY"), "\(plan)")
        #expect(!plan.contains("TEMP B-TREE"), "\(plan)")
    }

    @Test func threadLookupsAndCounts() throws {
        let (store, account) = try seeded(count: 3)
        let ref = try #require(try store.thread(account: account, gmailThreadID: GmailThreadID("t-m1")))
        #expect(try store.thread(ref)?.subject == "S1")
        #expect(try store.thread(account: account, gmailThreadID: GmailThreadID("nope")) == nil)
        let counts = try store.counts(account: account)
        #expect(counts.inboxUnread == 0)
        #expect(counts.byLabel.values.contains(LabelCount(total: 3, unread: 0)))
        #expect(try store.account(matching: "ME@example.com")?.id == account)
    }

    @Test func detailOrdersMessagesAndIncludesTrashed() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        let r = try store.upsertMessages([
            .fixture("b", thread: "t", minutes: 2, labels: ["INBOX"]),
            .fixture("a", thread: "t", minutes: 1, labels: ["TRASH"]),
        ], account: account, generation: 1)
        let detail = try detailOf(store, r)
        #expect(detail.messages.map(\.gmailMessageID.rawValue) == ["a", "b"])
        #expect(detail.messages.first?.inTrash == true)
        #expect(detail.thread.messageCount == 1)
        #expect(try store.threadDetail(ThreadRowID(rawValue: 9999)) == nil)
    }

    @Test func observeThreadListEmitsOnChangeButNotOnNoOp() async throws {
        let (store, account) = try seeded(count: 2)
        let observation = store.observeThreadList(view: .system(account, .inbox), limit: 10)
        var iterator = observation.values().makeAsyncIterator()
        let first = try #require(try await iterator.next())
        #expect(first.items.count == 2 && first.totalCount == 2 && !first.hasMore)
        _ = try store.upsertMessages([.fixture("x", labels: ["SENT"])], account: account, generation: 1)
        _ = try store.upsertMessages([.fixture("m9", minutes: 100, labels: ["INBOX"])], account: account, generation: 1)
        let second = try #require(try await iterator.next())
        #expect(second.items.count == 3 && second.items.first?.subject == "Hello")
    }

    @Test func observeImmediateCurrentValueAndDetailAndBody() async throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        let r = try store.upsertMessages([.fixture("m1")], account: account, generation: 1)
        let tid = try firstTid(r)
        let detailObs = store.observeThreadDetail(tid)
        var detailIt = detailObs.values().makeAsyncIterator()
        let d1 = try #require(try await detailIt.next())
        let mid = try #require(d1?.messages.first?.id)
        let bodyObs = store.observeBody(mid)
        var bodyIt = bodyObs.values().makeAsyncIterator()
        let b1 = try await bodyIt.next()
        #expect(b1 == .some(nil))
        try store.storeBodies([(GmailMessageID("m1"), .fixture(), [])], account: account)
        let b2 = try #require(try await bodyIt.next())
        #expect(b2?.text == "Hi")
        let d2 = try #require(try await detailIt.next())
        #expect(d2?.messages.first?.bodyState == .stored)
    }

    @MainActor @Test func startDeliversFirstValueSynchronously() throws {
        let (store, account) = try seeded(count: 1)
        var got: ThreadWindow?
        let token = store.observeThreadList(view: .system(account, .inbox), limit: 5)
            .start(onError: { _ in }, onChange: { got = $0 })
        #expect(got?.items.count == 1)
        token.cancel()
    }
}
