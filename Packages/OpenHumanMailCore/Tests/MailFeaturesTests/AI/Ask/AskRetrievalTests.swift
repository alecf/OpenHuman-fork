import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct AskRetrievalTests {
    static let work = AskFixture.work

    func source(threads: Int = 60) -> AskTestSource {
        AskTestSource(FakeMailStore(corpus: .rich(threadCount: threads, now: fixedNow),
                                    options: .init(remoteAck: .immediate, now: { fixedNow })))
    }

    @Test func keywordsSearchEveryWordThenAnyWordWithAtMostTwelveConversations() async throws {
        let source = source(threads: 300)
        let retriever = MailAskRetriever(data: source, clock: TestClock())
        let retrieval = try await retriever.retrieve("When is the offsite planning review?", scope: .account(Self.work),
                                                     plan: nil)
        let everyWord = "offsite planning review", anyWord = "offsite OR planning OR review"
        #expect(source.searches == [.init(query: everyWord, semanticText: everyWord, accounts: [Self.work]),
                                    .init(query: anyWord, semanticText: everyWord, accounts: [Self.work])])

        let a = try #require(try await firstAnswer(source.store.search(everyWord, accounts: [Self.work], limit: 20))).hits
        let b = try #require(try await firstAnswer(source.store.search(anyWord, accounts: [Self.work], limit: 20))).hits
        var expected: [ThreadKey] = []
        for hit in a + b where !expected.contains(hit.row.id) { expected.append(hit.row.id) }
        try #require(expected.count > MailAskRetriever.maxConversations, "the corpus has more than 12 to choose from")
        expected = Array(expected.prefix(MailAskRetriever.maxConversations))
        #expect(retrieval.otherThreads.map(\.thread) == expected)

        #expect(!retrieval.candidates.isEmpty && retrieval.candidates.count <= AIPolicy.askInboxMaxCandidates)
        let threads = retrieval.candidates.compactMap { retrieval.sources[$0.messageKey]?.thread }
        #expect(threads.count == retrieval.candidates.count)
        #expect(Dictionary(grouping: threads, by: { $0 }).values.allSatisfy { $0.count <= MailAskRetriever.maxPerConversation })
        let first = try #require(try await firstAnswer(source.store.threadDetail(expected[0])) ?? nil)
        let picked = retrieval.candidates.compactMap { retrieval.keys[$0.messageKey] }
            .filter { retrieval.sources[AIThreadLoader.messageKey($0)]?.thread == expected[0] }
        #expect(picked == Array(first.messages.suffix(2).reversed().map(\.id)))

        let me = try #require(try await firstAnswer(source.accounts())?.first { $0.id == Self.work })
        for candidate in retrieval.candidates {
            let key = try #require(retrieval.keys[candidate.messageKey])
            #expect(candidate.messageKey == "\(key.account.rawValue).\(key.gmailMessageID.rawValue)")
            #expect(candidate.accountKey == AICenter.policyKey(email: me.email))
            #expect(!candidate.bodyText.isEmpty && candidate.subject != nil)
        }
        #expect(retrieval.queryText == anyWord && retrieval.gmailQuery == everyWord && retrieval.queryAccount == Self.work)
        #expect(retrieval.searched == everyWord)
        #expect(retrieval.planLine.hasPrefix("Searched Work for “offsite planning review” · 12 conversations"))
        #expect(retrieval.completeness == nil, "the fake's local answers are complete")
    }

    @Test func allAccountsSearchesEveryAccountAndSaysSo() async throws {
        let source = source()
        let retrieval = try await MailAskRetriever(data: source, clock: TestClock())
            .retrieve("offsite planning", scope: .allAccounts, plan: nil)
        #expect(source.searches.allSatisfy { $0.accounts == nil })
        #expect(retrieval.queryAccount == nil)
        #expect(retrieval.planLine.hasPrefix("Searched all accounts for “offsite planning”"))
    }

    @Test func aBodyThatDoesNotArriveInTimeReadsFromItsSnippet() async throws {
        let source = source()
        let hits = try #require(try await firstAnswer(source.store.search("offsite planning", accounts: [Self.work],
                                                                         limit: 20))).hits
        let firstHit = try #require(hits.first)
        let detail = try #require(try await firstAnswer(source.store.threadDetail(firstHit.row.id)) ?? nil)
        let held = try #require(detail.messages.last)
        source.hold([held.id])
        let clock = TestClock()
        let retriever = MailAskRetriever(data: source, clock: clock)
        let task = Task { try await retriever.retrieve("offsite planning", scope: .account(Self.work), plan: nil) }
        await eventually { clock.sleeperCount == 1 && source.bodyReads.contains(held.id) }
        clock.advance(by: .milliseconds(1_500))
        let retrieval = try await task.value
        let candidate = try #require(retrieval.candidates.first { retrieval.keys[$0.messageKey] == held.id })
        #expect(candidate.bodyText == held.snippet)
        #expect(retrieval.planLine.contains("read from previews"))
    }

    @Test func thisConversationReadsOnlyThatConversationAndSearchesNothing() async throws {
        let source = source()
        let hits = try #require(try await firstAnswer(source.store.search("hiring loop", accounts: [Self.work],
                                                                         limit: 20))).hits
        var chosen: ConversationDetail?
        for hit in hits {
            let detail = try await firstAnswer(source.store.threadDetail(hit.row.id)) ?? nil
            if let detail, detail.messages.count >= 3 {
                chosen = detail
                break
            }
        }
        let detail = try #require(chosen, "a conversation with three or more messages")
        let retrieval = try await MailAskRetriever(data: source, clock: TestClock())
            .retrieve("what did we decide?", scope: .conversation(detail.id), plan: nil)
        #expect(source.searches.isEmpty, "no search for one conversation")
        let ids = Set(detail.messages.map(\.id))
        #expect(retrieval.candidates.count == min(detail.messages.count, MailAskRetriever.conversationMessages))
        #expect(retrieval.candidates.allSatisfy { retrieval.keys[$0.messageKey].map(ids.contains) == true })
        #expect(retrieval.planLine == "Read “\(detail.subject)” (\(retrieval.candidates.count) messages)")
        #expect(retrieval.queryText == nil && retrieval.gmailQuery == nil && retrieval.otherThreads.isEmpty)
    }

    @Test func aQuestionWithoutWordsSearchesNothing() async throws {
        let source = source()
        let retriever = MailAskRetriever(data: source, clock: TestClock())
        await #expect(throws: AskRetrievalError.noUsableWords) {
            _ = try await retriever.retrieve("is it so?", scope: .account(Self.work), plan: nil)
        }
        #expect(source.searches.isEmpty)
    }

    @Test func theLocalIndexCoverageReachesTheRetrieval() async throws {
        let source = source()
        let back = Date(timeIntervalSince1970: 1_710_000_000)
        source.olderMailMissing(searchedBack: back)
        let retrieval = try await MailAskRetriever(data: source, clock: TestClock())
            .retrieve("wifi password cabin", scope: .account(Self.work), plan: nil)
        #expect(retrieval.completeness == AskCompleteness(searchedBack: back))
        #expect(retrieval.gmailQuery == "wifi password cabin")
    }

    @Test func aPlanIsSearchedFirstWithItsTopic() async throws {
        let source = source()
        let plan = AskPlan(query: "subject:offsite", chips: ["“offsite”"], semanticText: "the team offsite")
        let retrieval = try await MailAskRetriever(data: source, clock: TestClock())
            .retrieve("anything about the offsite since last week", scope: .account(Self.work), plan: plan)
        #expect(source.searches == [.init(query: "subject:offsite", semanticText: "the team offsite", accounts: [Self.work])],
                "a plan that found mail is the whole search")
        #expect(!retrieval.candidates.isEmpty)
        #expect(retrieval.planLine.hasPrefix("Searched Work: “offsite” · "))
        #expect(retrieval.queryText == "subject:offsite")
    }

    @Test func theKeywordsStandInWhenThePlanFindsNothing() async throws {
        let source = source()
        let plan = AskPlan(query: "subject:zzqqxx", chips: ["“zzqqxx”"])
        let retrieval = try await MailAskRetriever(data: source, clock: TestClock())
            .retrieve("offsite planning", scope: .account(Self.work), plan: plan)
        #expect(source.searches.map(\.query) == ["subject:zzqqxx", "offsite planning", "offsite OR planning"])
        #expect(source.searches.allSatisfy { $0.semanticText == "offsite planning" }, "no topic: the keywords")
        #expect(!retrieval.candidates.isEmpty)
        #expect(retrieval.planLine.hasPrefix("Searched Work for “offsite planning”"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1"))
    func retrievalStaysWithinItsBudget() async throws {
        let source = source(threads: 2_000)
        let retriever = MailAskRetriever(data: source, clock: TestClock())
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<20 {
            let start = clock.now
            _ = try await retriever.retrieve("offsite planning review budget", scope: .account(Self.work), plan: nil)
            times.append(clock.now - start)
        }
        times.sort()
        #expect(times[18] < .milliseconds(400), "p95 \(times[18])")
    }

    @Test func olderMailAsksGmailForTwentyAndFetchesAtMostTenBodies() async throws {
        let source = source(threads: 120)
        let rows = try await source.store.threadPage(.system(.inbox), account: Self.work, after: nil, limit: 100).rows
        source.gmailFinds(Array(rows.map(\.id).prefix(30)))
        let retrieval = try await MailAskRetriever(data: source, clock: TestClock())
            .retrieveOlderMail("dentist appointment", gmailQuery: "dentist appointment", account: Self.work)
        #expect(source.gmailCalls == [.init(query: "dentist appointment", account: Self.work, maxResults: 20)])
        #expect(source.searches.isEmpty, "Gmail's conversations, not a local search")
        #expect(retrieval.otherThreads.count == MailAskRetriever.maxConversations)
        #expect(retrieval.candidates.count <= AIPolicy.askInboxMaxCandidates)
        #expect(source.bodyReads.count == MailAskRetriever.olderMailBodies, "at most 10 bodies fetched")
        #expect(retrieval.planLine.hasPrefix("Searched Gmail for “dentist appointment” · 12 conversations"))
        #expect(retrieval.gmailQuery == nil, "never offered twice")
    }
}
