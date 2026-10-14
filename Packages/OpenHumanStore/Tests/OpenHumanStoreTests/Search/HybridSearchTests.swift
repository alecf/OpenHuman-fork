import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite("Hybrid search")
struct HybridSearchTests {
    private func mid(_ fixture: SearchFixture, _ gmail: String) throws -> MessageRowID {
        let raw = try fixture.store.read { db in
            try Int64.fetchOne(db, sql: "SELECT mid FROM messages WHERE gmail_message_id = ?", arguments: [gmail])
        }
        return MessageRowID(rawValue: try #require(raw))
    }

    private func candidates(_ fixture: SearchFixture, _ pairs: [(String, Double)]) throws -> ExternalSearchCandidates {
        ExternalSearchCandidates(source: .semantic, candidates: try pairs.map { gmail, score in
            ExternalSearchCandidate(message: try mid(fixture, gmail), gmailMessageID: GmailMessageID(gmail), score: score)
        })
    }

    private func hybrid(_ fixture: SearchFixture, _ text: String, _ external: ExternalSearchCandidates?, limit: Int = 50,
                        after: ThreadCursor? = nil) throws -> SearchPage {
        try fixture.store.search(try fixture.store.parseSearch(text), accounts: nil, after: after, limit: limit,
                                 external: external, ranking: HybridRRFRanking(), now: searchTestNow)
    }

    private func subjects(_ page: SearchPage) -> [String] { page.hits.map(\.thread.subject) }

    @Test func noCandidatesIsExactlyMUR1() throws {
        let fixture = try SearchFixture()
        for text in ["invoice", "from:alice@example.com", "invoice -label:Clients/Acme", "in:anywhere invoice", "ai"] {
            let query = try fixture.store.parseSearch(text)
            let plain = try fixture.store.search(query, accounts: nil, after: nil, limit: 50, ranking: BM25RecencyRanking(),
                                                 now: searchTestNow)
            let none = try fixture.store.search(query, accounts: nil, after: nil, limit: 50, external: nil,
                                                ranking: BM25RecencyRanking(), now: searchTestNow)
            let empty = try fixture.store.search(query, accounts: nil, after: nil, limit: 50,
                                                 external: ExternalSearchCandidates(source: .semantic, candidates: []),
                                                 ranking: BM25RecencyRanking(), now: searchTestNow)
            #expect(none == plain)
            #expect(empty == plain)
            #expect(plain.hits.allSatisfy { $0.sources == [.lexical] && $0.bestMessageID == nil })
        }
    }

    @Test func relatedThreadJoinsTheLexicalOnes() throws {
        let fixture = try SearchFixture()
        let page = try hybrid(fixture, "invoice", try candidates(fixture, [("lunch", 0.9), ("inv1", 0.8)]))
        let lunch = try #require(page.hits.first { $0.thread.subject == "Lunch tomorrow?" })
        #expect(lunch.sources == [.semantic])
        #expect(lunch.highlight == nil)
        #expect(lunch.bestMessageID == (try mid(fixture, "lunch")))
        let invoice = try #require(page.hits.first { $0.thread.subject.contains("Quarterly invoice") })
        #expect(invoice.sources == [.lexical, .semantic])
        #expect(invoice.highlight != nil)
        let lexical = try hybrid(fixture, "invoice", nil)
        #expect(Set(subjects(lexical)).isSubset(of: Set(subjects(page))))
    }

    @Test func candidatesObeyTheScope() throws {
        let fixture = try SearchFixture()
        let external = try candidates(fixture, [("spam", 0.99), ("trash", 0.98), ("draft", 0.97), ("lunch", 0.5)])
        let page = try hybrid(fixture, "invoice", external)
        let related = page.hits.filter { $0.sources == [.semantic] }.map(\.thread.subject)
        #expect(related == ["Lunch tomorrow?"])
        let trash = try hybrid(fixture, "in:trash invoice", external)
        #expect(subjects(trash).contains("Old invoice"))
        #expect(!subjects(trash).contains("Lunch tomorrow?"))
    }

    @Test func candidatesObeyStructuredOperators() throws {
        let fixture = try SearchFixture()
        let external = try candidates(fixture, [("news", 0.9), ("lunch", 0.8), ("cjk", 0.7)])
        let cases: [(String, Set<String>)] = [
            ("zebra from:alice@example.com", ["Lunch tomorrow?"]),
            ("weekly is:starred", ["Lunch tomorrow?"]),
            ("lunch list:weekly.list.example.com", ["Weekly newsletter"]),
            ("lunch -from:alice@example.com", ["Weekly newsletter", "会議の議事録"]),
            ("lunch before:2020/01/01", []),
        ]
        for (text, expected) in cases {
            let related = Set(try hybrid(fixture, text, external).hits.filter { !$0.sources.contains(.lexical) }.map(\.thread.subject))
            #expect(related == expected, "\(text)")
        }
    }

    @Test func reusedRowidIsDropped() throws {
        let fixture = try SearchFixture()
        let stale = ExternalSearchCandidates(source: .semantic, candidates: [
            ExternalSearchCandidate(message: try mid(fixture, "lunch"), gmailMessageID: GmailMessageID("another-message"), score: 1),
        ])
        #expect(try hybrid(fixture, "invoice", stale).hits.allSatisfy { $0.sources.contains(.lexical) })
    }

    @Test func rrfMatchesTheFormulaAndBreaksTiesDeterministically() {
        let now = searchTestNow
        func candidate(_ tid: Int64, bm25: Double?, external: Double?, minutesAgo: Double) -> SearchCandidate {
            SearchCandidate(threadID: ThreadRowID(rawValue: tid), bestMessageID: MessageRowID(rawValue: tid),
                            matchedMessageIDs: [MessageRowID(rawValue: tid)], bestAt: now.addingTimeInterval(-minutesAgo * 60),
                            newestAt: now.addingTimeInterval(-minutesAgo * 60), bm25: bm25, externalScore: external)
        }
        let a = candidate(1, bm25: -5, external: nil, minutesAgo: 30)
        let b = candidate(2, bm25: -2, external: 0.9, minutesAgo: 10)
        let c = candidate(3, bm25: nil, external: 0.4, minutesAgo: 20)
        let scores = HybridRRFRanking().scores(for: [a, b, c], query: SearchQuery(text: "", terms: []), now: now)
        let k = 60.0
        #expect(abs(scores[0] - (1 / (k + 1) + 0.25 / (k + 3))) < 1e-12)
        #expect(abs(scores[1] - (1 / (k + 2) + 1 / (k + 1) + 0.25 / (k + 1))) < 1e-12)
        #expect(abs(scores[2] - (1 / (k + 2) + 0.25 / (k + 2))) < 1e-12)
        let tie1 = candidate(7, bm25: -1, external: nil, minutesAgo: 5), tie2 = candidate(9, bm25: -1, external: nil, minutesAgo: 5)
        #expect(HybridRRFRanking.ranks([tie1, tie2], by: { $0.bm25.map { -$0 } }) == [2, 1])
        #expect(HybridRRFRanking().scores(for: [a, b, c], query: SearchQuery(text: "", terms: []), now: now) == scores)
    }

    @Test func hybridPagesCoverEveryThreadOnce() throws {
        let fixture = try SearchFixture()
        let external = try candidates(fixture, [("lunch", 0.9), ("news", 0.8), ("cjk", 0.7), ("short", 0.6)])
        let all = try hybrid(fixture, "invoice", external)
        var seen: [ThreadRowID] = []
        var cursor: ThreadCursor?
        repeat {
            let page = try hybrid(fixture, "invoice", external, limit: 2, after: cursor)
            seen += page.hits.map(\.thread.id)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(seen == all.hits.map(\.thread.id))
        #expect(Set(seen).count == seen.count)
    }

    @Test func observationEmitsTheFusedPage() async throws {
        let fixture = try SearchFixture()
        let external = try candidates(fixture, [("lunch", 0.9)])
        let query = try fixture.store.parseSearch("invoice")
        var iterator = fixture.store.observeSearch(query, accounts: nil, limit: 50, external: external).values().makeAsyncIterator()
        let page = try #require(try await iterator.next())
        #expect(page.hits.contains { $0.sources == [.semantic] && $0.thread.subject == "Lunch tomorrow?" })
    }

    @Test func structuredMessageIDsIgnoreFreeText() throws {
        let fixture = try SearchFixture()
        let lunch = try mid(fixture, "lunch")
        for text in ["from:alice@example.com", "zebra from:alice@example.com", "{zebra yak} from:alice@example.com"] {
            let found = try fixture.store.structuredMessageIDs(try fixture.store.parseSearch(text), accounts: nil, limit: 10)
            #expect(found.ids == [lunch], "\(text)")
            #expect(!found.capped)
        }
        let capped = try fixture.store.structuredMessageIDs(try fixture.store.parseSearch("in:inbox"), accounts: nil, limit: 1)
        #expect(capped.ids.count == 1 && capped.capped)
    }

    @Test func indexableMessagesWalkRowidOrder() throws {
        let fixture = try SearchFixture()
        let first = try fixture.store.indexableMessages(afterMessage: nil, limit: 3)
        #expect(first.count == 3)
        #expect(first.map(\.message.rawValue) == first.map(\.message.rawValue).sorted())
        let rest = try fixture.store.indexableMessages(afterMessage: first.last?.message, limit: 100)
        #expect(rest.count == 7)
        #expect(Set((first + rest).map(\.message)).count == 10)
        let spam = try #require((first + rest).first { $0.gmailMessageID == GmailMessageID("spam") })
        #expect(spam.inSpam && !spam.isDraft)
        let byID = try fixture.store.indexableMessages([spam.message, MessageRowID(rawValue: 999_999)])
        #expect(byID == [spam])
    }

    @Test func documentsCarryTheRecipeParts() throws {
        let fixture = try SearchFixture()
        let inv1 = try mid(fixture, "inv1")
        let document = try #require(try fixture.store.indexableDocuments([inv1]).first)
        #expect(document.subject == "Quarterly invoice from Acme")
        #expect(document.fromName == "Acme Billing")
        #expect(document.attachmentNames == ["invoice-2026.pdf"])
        #expect(document.body.contains("Payment due"))
        #expect(try fixture.store.messageIdentities([inv1]) == [inv1: GmailMessageID("inv1")])
    }

    @Test func bodyStatusCountsAndEpoch() throws {
        let fixture = try SearchFixture()
        #expect(try fixture.store.indexableCount(account: fixture.account) == 8)
        #expect(try fixture.store.bodyDownloadStatus(account: fixture.account) == .downloading)
        try fixture.store.setSetting(.bodyMaxMessages, 0, scope: .global)
        #expect(try fixture.store.bodyDownloadStatus(account: fixture.account) == .capped)
        try fixture.store.setSetting(.downloadBodies, false, scope: .global)
        #expect(try fixture.store.bodyDownloadStatus(account: fixture.account) == .off)
        let epoch = try fixture.store.storeEpoch()
        let again = try fixture.store.storeEpoch()
        #expect(!epoch.isEmpty && epoch == again)
        let awaiting = try fixture.store.read { db in
            try Int64.fetchAll(db, sql: "SELECT mid FROM messages WHERE account_id = ? AND body_state < 2 ORDER BY mid",
                               arguments: [fixture.account.rawValue])
        }
        #expect(try fixture.store.messageIDsAwaitingBodies(account: fixture.account).map(\.rawValue).sorted() == awaiting)
    }
}
