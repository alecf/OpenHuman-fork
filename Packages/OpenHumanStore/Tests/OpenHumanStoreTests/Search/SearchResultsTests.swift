import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct SearchRankingTests {
    private func twoThreads() throws -> SearchFixture {
        let f = try SearchFixture()
        _ = try f.store.upsertMessages([
            .fixture("r1", minutes: 5, subject: "Budget review", snippet: "x", body: .fixture(html: nil, text: "numbers")),
            .fixture("r2", minutes: 6, subject: "Hello", snippet: "x", body: .fixture(html: nil, text: "the budget is attached")),
        ], account: f.account, generation: 1)
        return f
    }

    @Test func aSubjectMatchOutranksABodyMatchAtEqualAge() throws {
        let f = try twoThreads()
        let ranking = BM25RecencyRanking(relevanceWeight: 1, recencyWeight: 0)
        let page = try f.store.search(try parseSearchQuery("budget"), accounts: nil, after: nil, limit: 10, ranking: ranking, now: searchTestNow)
        #expect(page.hits.map(\.thread.ref.gmailThreadID.rawValue) == ["t-r1", "t-r2"])
    }

    @Test func recencyBreaksTiesAndCanDominate() throws {
        let f = try SearchFixture()
        _ = try f.store.upsertMessages([
            .fixture("old", minutes: -60 * 24 * 365, subject: "Status report", snippet: "x"),
            .fixture("new", minutes: 5, subject: "Status report", snippet: "x"),
        ], account: f.account, generation: 1)
        let q = try parseSearchQuery("status report")
        let both = try f.store.search(q, accounts: nil, after: nil, limit: 10, ranking: BM25RecencyRanking(), now: searchTestNow)
        #expect(both.hits.map(\.thread.ref.gmailThreadID.rawValue) == ["t-new", "t-old"])
        let relevanceOnly = try f.store.search(q, accounts: nil, after: nil, limit: 10,
                                               ranking: BM25RecencyRanking(relevanceWeight: 1, recencyWeight: 0), now: searchTestNow)
        #expect(Set(relevanceOnly.hits.map(\.thread.ref.gmailThreadID.rawValue)) == ["t-new", "t-old"])
    }

    @Test func aCustomRankerPlugsInWithoutChangingTheCaller() throws {
        struct OldestFirst: SearchRanking {
            func scores(for candidates: [SearchCandidate], query: SearchQuery, now: Date) -> [Double] {
                candidates.map { -$0.newestAt.timeIntervalSince1970 / 1e10 }
            }
        }
        let f = SearchFixture.shared
        let page = try f.store.search(try parseSearchQuery("invoice"), accounts: nil, after: nil, limit: 10, ranking: OldestFirst(), now: searchTestNow)
        #expect(page.hits.map(\.thread.ref.gmailThreadID.rawValue) == ["t-ancient", "T-inv"])
    }

    @Test func structuredOnlyQueriesAreNewestFirst() throws {
        let f = SearchFixture.shared
        let ids = try f.threads("in:inbox")
        #expect(ids == ["t-short", "t-cjk", "t-news", "t-lunch", "T-inv", "t-ancient"])
    }

    @Test func hitSortAtIsTheBestMessagesDate() throws {
        let f = SearchFixture.shared
        let hit = try #require(try f.search("zeppelin").hits.first)
        #expect(hit.thread.sortAt == Date(timeIntervalSince1970: SearchFixture.t0))
        #expect(hit.matchedMessageIDs.count == 1)
    }
}

@Suite struct SearchPaginationTests {
    private func many(_ n: Int) throws -> SearchFixture {
        let f = try SearchFixture()
        let messages = (0..<n).map { i in
            MessageUpsert.fixture("p\(i)", minutes: 100 + i, subject: "pageword \(i)", snippet: "x",
                                  body: .fixture(html: nil, text: String(repeating: "filler ", count: i % 7) + "pageword"))
        }
        _ = try f.store.upsertMessages(messages, account: f.account, generation: 1)
        return f
    }

    private func walk(_ f: SearchFixture, _ text: String, pageSize: Int) throws -> [String] {
        var seen: [String] = []
        var cursor: ThreadCursor?
        for _ in 0..<100 {
            let page = try f.search(text, limit: pageSize, after: cursor)
            seen += page.hits.map { $0.thread.ref.gmailThreadID.rawValue }
            guard let next = page.nextCursor else { return seen }
            cursor = next
        }
        Issue.record("pagination did not end")
        return seen
    }

    @Test func rankedPagesCoverEveryThreadOnceInTheSameOrderAsOnePage() throws {
        let f = try many(47)
        let all = try f.threads("pageword")
        #expect(all.count == 47 && Set(all).count == 47)
        let paged = try walk(f, "pageword", pageSize: 10)
        #expect(paged == all)
    }

    @Test func structuredPagesCoverEveryThreadOnceNewestFirst() throws {
        let f = try many(47)
        let all = try f.search("in:inbox", limit: 500).hits.map { $0.thread.ref.gmailThreadID.rawValue }
        #expect(all.count == 53)
        let paged = try walk(f, "in:inbox", pageSize: 8)
        #expect(paged == all && Set(paged).count == all.count)
        #expect(all.first == "t-p46")
    }

    @Test func shortTermPagesAlsoWalk() throws {
        let f = try many(30)
        let all = try f.threads("pa")
        #expect(try walk(f, "pa", pageSize: 7) == all)
        #expect(all.count >= 30)
    }

    @Test func limitIsClamped() throws {
        let f = try many(5)
        #expect(try f.search("pageword", limit: 0).hits.count == 1)
        #expect(try f.search("pageword", limit: 100_000).hits.count == 5)
    }
}

@Suite struct SearchHighlightTests {
    let f = SearchFixture.shared

    @Test func theBestMessageGetsAMarkedSnippet() throws {
        let hit = try #require(try f.search("zeppelin").hits.first)
        let snippet = try #require(hit.highlight)
        #expect(snippet.contains("\u{2}") && snippet.contains("\u{3}"))
        let marked = snippet.components(separatedBy: "\u{2}").dropFirst().map { $0.components(separatedBy: "\u{3}")[0] }
        #expect(marked.contains { $0.lowercased().contains("zep") })
    }

    @Test func subjectMatchesAreMarkedInTheSubjectColumn() throws {
        let hit = try #require(try f.search("subject:lunch").hits.first)
        #expect(hit.highlight?.contains("\u{2}") == true)
    }

    @Test func structuredAndShortTermQueriesHaveNoHighlight() throws {
        #expect(try f.search("is:unread").hits.allSatisfy { $0.highlight == nil })
        #expect(try f.search("ai").hits.allSatisfy { $0.highlight == nil })
    }

    @Test func markersInIndexedTextCannotComeFromTheQuery() throws {
        let page = try f.search("\u{2}zeppelin\u{3}")
        #expect(page.hits.count == 1)
    }
}

@Suite struct SearchCompletenessTests {
    @Test func aNotYetBackfilledAccountSaysOlderMailNeedsTheGmailFallback() throws {
        let f = try SearchFixture(complete: false)
        let page = try f.search("invoice from:acme")
        #expect(page.completeness.needsGmailFallback && !page.completeness.isComplete)
        #expect(page.completeness.gmailQuery == "invoice from:acme")
        guard case let .olderMailNeedsGmailFallback(accounts, searchedBack) = page.completeness.reasons.first else {
            Issue.record("no fallback reason: \(page.completeness.reasons)"); return
        }
        #expect(accounts == [f.account] && searchedBack == nil)
    }

    @Test func theReasonCarriesHowFarBackTheLocalCopyReaches() throws {
        let f = try SearchFixture(complete: false)
        try f.store.write { db in
            try db.execute(sql: "UPDATE sync_state SET backfill_oldest_at = ? WHERE account_id = ?", arguments: [1_780_000_000_000, f.account.rawValue])
        }
        let page = try f.search("invoice")
        guard case let .olderMailNeedsGmailFallback(_, searchedBack) = page.completeness.reasons.first else {
            Issue.record("no reason"); return
        }
        #expect(searchedBack == Date(timeIntervalSince1970: 1_780_000_000))
    }

    @Test func aLowerDateBoundInsideTheWindowIsComplete() throws {
        let f = try SearchFixture(complete: false)
        try f.store.write { db in
            try db.execute(sql: "UPDATE sync_state SET backfill_oldest_at = ? WHERE account_id = ?", arguments: [1_780_000_000_000, f.account.rawValue])
        }
        #expect(try f.search("in:sent after:2026/09/01").completeness.needsGmailFallback == false)
        #expect(try f.search("in:sent after:2026/01/01").completeness.needsGmailFallback == true)
        #expect(try f.search("in:sent before:2026/09/01").completeness.needsGmailFallback == true)
    }

    @Test func aBackfilledAccountWithStoredBodiesIsComplete() throws {
        let f = try SearchFixture()
        try f.store.write { db in try db.execute(sql: "UPDATE messages SET body_state = 2") }
        #expect(try f.search("invoice").completeness.isComplete)
    }

    @Test func metadataOnlyMessagesAreFlaggedForBodyTerms() throws {
        let f = try SearchFixture()
        _ = try f.store.upsertMessages([.fixture("meta", minutes: 3, labels: ["INBOX"], subject: "Metadata only", snippet: "just a snippet")],
                                       account: f.account, generation: 1)
        try f.store.write { db in try db.execute(sql: "UPDATE messages SET body_state = 2 WHERE gmail_message_id <> 'meta'") }
        let page = try f.search("snippet")
        #expect(page.completeness.reasons == [.bodiesPartiallyIndexed(messages: 1)])
        #expect(try f.search("is:unread").completeness.isComplete)
        #expect(try f.search("subject:metadata").completeness.isComplete)
    }

    @Test func gmailQueryIsAlwaysProvidedForTheFallback() throws {
        let f = SearchFixture.shared
        let page = try f.search("from:alice -label:work before:2026/01/01")
        #expect(page.completeness.gmailQuery == "from:alice -label:work before:1767225600")
    }

    @Test func emptyResultsStillCarryTheSignal() throws {
        let f = try SearchFixture(complete: false)
        let page = try f.search("nothingmatchesthis")
        #expect(page.hits.isEmpty && page.completeness.needsGmailFallback)
    }

    @Test func removedAccountsAreNotCounted() throws {
        let f = try SearchFixture()
        let other = try f.store.addAccount(email: "gone@example.com", displayName: nil, scopes: [])
        try f.store.write { db in try db.execute(sql: "UPDATE accounts SET status = 'removing' WHERE account_id = ?", arguments: [other.rawValue]) }
        #expect(try f.search("invoice").completeness.needsGmailFallback == false)
    }
}

@Suite struct SearchObservationTests {
    @Test func observeSearchEmitsNewResultsAndNotNoOps() async throws {
        let f = try SearchFixture()
        let observation = f.store.observeSearch(try parseSearchQuery("sushi"), accounts: nil, limit: 10)
        var iterator = observation.values().makeAsyncIterator()
        let first = try #require(try await iterator.next())
        #expect(first.hits.count == 1)
        _ = try f.store.upsertMessages([.fixture("sushi2", minutes: 501, subject: "More sushi", snippet: "x")], account: f.account, generation: 1)
        let second = try #require(try await iterator.next())
        #expect(second.hits.count == 2)
    }

    @MainActor @Test func startDeliversTheFirstPageSynchronously() throws {
        let f = try SearchFixture()
        var got: SearchPage?
        let token = f.store.observeSearch(try parseSearchQuery("sushi"), accounts: nil, limit: 5)
            .start(onError: { _ in }, onChange: { got = $0 })
        #expect(got?.hits.count == 1)
        token.cancel()
    }
}

@Suite struct SearchEnvironmentTests {
    @Test func theLinkedSQLiteHasFTS5TrigramAndSnippet() throws {
        let store = try MailStore.openInMemoryForTesting()
        try store.read { db in
            let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? ""
            let parts = version.split(separator: ".").compactMap { Int($0) }
            #expect(parts.count >= 2 && (parts[0], parts[1]) >= (3, 44), "sqlite \(version)")
            let options = try String.fetchAll(db, sql: "PRAGMA compile_options")
            #expect(options.contains("ENABLE_FTS5"), "\(options)")
            let json = try String.fetchOne(db, sql: "SELECT json_extract('{\"e\":\"x\"}', '$.e')")
            #expect(json == "x")
        }
    }

    @Test func trigramAcceleratesLikeAndSnippetAndHighlightWorkOnTheExternalContentTable() throws {
        let f = SearchFixture.shared
        try f.store.read { db in
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT rowid FROM messages_fts WHERE body LIKE '%zeppelin%'")
                .map { ($0["detail"] as String) }.joined(separator: " | ")
            #expect(plan.contains("VIRTUAL TABLE INDEX"), "\(plan)")
            let like = try Int64.fetchAll(db, sql: "SELECT rowid FROM messages_fts WHERE body LIKE '%zeppelin%'")
            #expect(like.count == 1)
            let glob = try Int64.fetchAll(db, sql: "SELECT rowid FROM messages_fts WHERE body GLOB '*eppeli*'")
            #expect(glob == like)
            let snippet = try String.fetchOne(db, sql: """
                SELECT snippet(messages_fts, 2, '[', ']', '...', 8) FROM messages_fts WHERE messages_fts MATCH '"zeppelin"'
                """)
            #expect(snippet?.contains("[Zeppelin]") == true, "\(snippet ?? "nil")")
            let highlight = try String.fetchOne(db, sql: """
                SELECT highlight(messages_fts, 0, '[', ']') FROM messages_fts WHERE messages_fts MATCH 'subject : "invoice"' LIMIT 1
                """)
            #expect(highlight?.contains("[invoice]") == true, "\(highlight ?? "nil")")
            let cjk = try String.fetchOne(db, sql: """
                SELECT snippet(messages_fts, 0, '[', ']', '...', 8) FROM messages_fts WHERE messages_fts MATCH '"議事録"'
                """)
            #expect(cjk?.contains("[議事録]") == true, "\(cjk ?? "nil")")
        }
    }
}
