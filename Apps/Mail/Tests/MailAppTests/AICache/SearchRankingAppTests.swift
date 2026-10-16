import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanStore
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

private let now = Date(timeIntervalSince1970: 1_791_000_000)

private func entry(_ account: Int64, _ thread: String, score: Double, daysAgo: Double = 0) -> SearchLearningEntry {
    SearchLearningEntry(account: AccountID(account), thread: GmailThreadID(thread),
                        history: SearchClickHistory(score: score, at: now.addingTimeInterval(-daysAgo * 86_400)))
}

private func key(_ account: Int64, _ row: Int64, _ thread: String) -> ThreadKey {
    ThreadKey(account: AccountID(account), rowID: row, gmailThreadID: GmailThreadID(thread))
}

@Suite struct SearchLearningStoreTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oh-search-learning-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func rowsSurviveARelaunchAndResetEmptiesTheFile() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLiteSearchLearningStore.fileName)
        let store = try SQLiteSearchLearningStore(url: url)
        await store.put(entry(1, "t1", score: 2))
        await store.put(entry(1, "t1", score: 3))
        await store.put(entry(2, "t2", score: 1, daysAgo: 10))
        #expect(await store.count == 2)
        #expect(await store.userVersion == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let reopened = try SQLiteSearchLearningStore(url: url)
        #expect(Set(reopened.initialEntries) == [entry(1, "t1", score: 3), entry(2, "t2", score: 1, daysAgo: 10)])
        await reopened.remove([(AccountID(2), GmailThreadID("t2"))])
        #expect(await reopened.count == 1)
        await reopened.removeAll()
        #expect(try SQLiteSearchLearningStore(url: url).initialEntries.isEmpty)
    }

    @Test func aDamagedFileIsSetAsideAndStartedAgain() throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(SQLiteSearchLearningStore.fileName)
        try Data("not a database".utf8).write(to: url)
        let store = try SQLiteSearchLearningStore(url: url)
        #expect(store.initialEntries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains("damaged") })
    }
}

@Suite struct SearchRankingServiceTests {
    private func service(_ learning: InMemorySearchLearningStore = InMemorySearchLearningStore(),
                         persistence: SearchRankingService.Persistence = .memory,
                         clock: @escaping @Sendable () -> Date = { now },
                         resolve: @escaping SearchRankingService.Resolve = { _, _ in nil }) -> SearchRankingService {
        SearchRankingService(persistence: persistence, learning: learning, resolve: resolve, now: clock)
    }

    @Test func balancedIsTheSameInTheAppAndTheStore() {
        #expect(SearchRankingService.storeWeights(.balanced) == BlendedSearchRanking.Weights.balanced)
        #expect(SearchRankingSettings.defaults.weights == .balanced)
    }

    @Test func theRankerFollowsTheSettingsAndTheSwitchForOneSearch() {
        let ranking = service()
        #expect(ranking.ranking(for: "quince", hybrid: false) is BlendedSearchRanking)
        ranking.setSortOverride(SearchSortOverride(query: "quince", sort: .recent))
        #expect(ranking.ranking(for: "quince", hybrid: true) is NewestFirstSearchRanking)
        #expect(ranking.ranking(for: "other", hybrid: false) is BlendedSearchRanking)
        ranking.save(SearchRankingSettings(preset: .classic))
        #expect(ranking.ranking(for: "other", hybrid: false) is BM25RecencyRanking)
        #expect(ranking.ranking(for: "other", hybrid: true) is HybridRRFRanking)
        ranking.save(SearchRankingSettings(sort: .recent))
        #expect(ranking.ranking(for: "other", hybrid: false) is NewestFirstSearchRanking)
    }

    @Test func settingsPersistInTheirOwnDefaultsSuite() {
        let suite = "dev.openhuman.mail.tests.searchRanking.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        service(persistence: .defaults(suite: suite)).save(SearchRankingSettings(sort: .recent, preset: .relevance))
        #expect(service(persistence: .defaults(suite: suite)).settings() == SearchRankingSettings(sort: .recent, preset: .relevance))
        #expect(service(persistence: .memory).settings() == .defaults)
    }

    @Test func opensFadeAccumulateAndAreForgotten() async {
        let learning = InMemorySearchLearningStore([entry(1, "old", score: 1, daysAgo: 400)])
        let ranking = service(learning, resolve: { _, thread in thread.rawValue == "old" ? ThreadRowID(rawValue: 77) : nil })
        #expect(await ranking.rememberedConversations() == 1)
        await ranking.recordOpen(key(1, 5, "t5"))
        await ranking.recordOpen(key(1, 5, "t5"))
        #expect(await ranking.rememberedConversations() == 1)
        #expect(await learning.count == 1)
        #expect(ranking.clicks() == [ThreadRowID(rawValue: 5): SearchClickHistory(score: 2, at: now)])
        await ranking.resetLearning()
        #expect(await ranking.rememberedConversations() == 0)
        #expect(await learning.count == 0)
        #expect(ranking.clicks().isEmpty)
        #expect(ranking.settings() == .defaults, "reset learning keeps the settings")
    }

    @Test func storedOpensAreResolvedByGmailThreadIDNotByAnOldRowID() {
        let learning = InMemorySearchLearningStore([entry(1, "kept", score: 1), entry(1, "deleted", score: 3)])
        let ranking = service(learning, resolve: { _, thread in thread.rawValue == "kept" ? ThreadRowID(rawValue: 900) : nil })
        #expect(ranking.clicks() == [ThreadRowID(rawValue: 900): SearchClickHistory(score: 1, at: now)])
    }

    @Test func openSearchesHearSettingAndSwitchChangesButNotOpens() async {
        let ranking = service()
        var changes = ranking.changes().makeAsyncIterator()
        #expect(ranking.listenerCount == 1)
        await ranking.recordOpen(key(1, 1, "t1"))
        ranking.save(.defaults)
        ranking.setSortOverride(SearchSortOverride(query: "q", sort: .recent))
        let heard: Void? = await changes.next()
        #expect(heard != nil)
        ranking.save(SearchRankingSettings(preset: .relevance))
        let again: Void? = await changes.next()
        #expect(again != nil)
    }
}

@Suite struct SearchRankingWindowTests {
    private static func store() throws -> (MailStore, AccountID) {
        let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 3, now: now))
        func message(_ id: String, daysAgo: Double, from: String, name: String, subject: String, body: String) -> MessageUpsert {
            MessageUpsert(
                gmailMessageID: GmailMessageID(id), gmailThreadID: GmailThreadID("t-\(id)"), historyID: HistoryID(20_000),
                internalDate: now.addingTimeInterval(-daysAgo * 86_400), labelIDs: [GmailLabelID("INBOX")], snippet: body,
                sizeEstimate: 10,
                headers: MessageHeaderFields(subject: subject, from: EmailAddress(name: name, email: from),
                                             to: [EmailAddress(email: FakeCorpus.me.email)], cc: [], bcc: [], replyTo: [],
                                             references: []),
                body: MessageBodyUpsert(html: nil, text: body, hasCalendarInvite: false, decodeWarnings: [], searchText: body))
        }
        _ = try store.upsertMessages([
            message("sender", daysAgo: 500, from: "developer@email.quince.example", name: "Quince Developer",
                    subject: "Quince Developer Program renewal", body: "Your membership renews soon."),
            message("news", daysAgo: 2, from: "news@byte.example", name: "The Weekly Byte", subject: "This week",
                    body: "Quince shipped developer tools. Every developer should try Quince."),
        ], account: account, generation: 1)
        return (store, account)
    }

    @Test func theWindowSaysHowItIsOrderedAndWhy() throws {
        let (store, account) = try Self.store()
        let query = try store.parseSearch("quince developer")
        let page = try store.search(query, accounts: [account], after: nil, limit: 10, ranking: BlendedSearchRanking(), now: now)
        let window = try MailStoreAdapter.searchWindow(page, remote: [], gmail: .notAsked, canAskGmail: false, store: store,
                                                       account: account, canSortByRelevance: query.isRankedByText)
        #expect(window.rows.map(\.id.gmailThreadID.rawValue) == ["t-sender", "t-news"])
        let status = try #require(window.search)
        #expect(status.ordering == .relevance)
        #expect(status.canSortByRelevance)
        #expect(status.explanations[window.rows[0].id.rowID]?.match == "sender name match")
        let recent = try store.search(query, accounts: [account], after: nil, limit: 10, ranking: NewestFirstSearchRanking(),
                                      now: now)
        let byDate = try MailStoreAdapter.searchWindow(recent, remote: [], gmail: .notAsked, canAskGmail: false, store: store,
                                                       account: account)
        #expect(byDate.rows.map(\.id.gmailThreadID.rawValue) == ["t-news", "t-sender"])
        #expect(byDate.search?.ordering == .date)
        #expect(byDate.search?.explanations.isEmpty == true)
    }

    @Test(.timeLimit(.minutes(1))) func aSortSwitchRunsTheOpenSearchAgain() async throws {
        let (store, account) = try Self.store()
        let ranking = SearchRankingService(persistence: .memory, learning: InMemorySearchLearningStore(),
                                           resolve: { _, _ in nil }, now: { now })
        let adapter = MailStoreAdapter(store: store, ranking: ranking)
        var windows = adapter.searchWindow("quince developer", account: account, limit: 10).makeAsyncIterator()
        var window = try #require(try await windows.next())
        #expect(window.search?.ordering == .relevance)
        #expect(window.rows.first?.id.gmailThreadID.rawValue == "t-sender")
        ranking.setSortOverride(SearchSortOverride(query: "quince developer", sort: .recent))
        repeat { window = try #require(try await windows.next()) } while window.search?.ordering != .date
        #expect(window.rows.first?.id.gmailThreadID.rawValue == "t-news")
    }
}
