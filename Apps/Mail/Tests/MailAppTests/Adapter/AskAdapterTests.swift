import Foundation
import MailFakes
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanMail

private let now = Date(timeIntervalSince1970: 1_791_000_000)

@discardableResult
private func put(_ store: MailStore, _ account: AccountID, id: String, subject: String, date: Date = now,
                 history: UInt64) throws -> ThreadRef {
    let threadID = GmailThreadID("t-\(id)")
    _ = try store.upsertMessages([MessageUpsert(
        gmailMessageID: GmailMessageID(id), gmailThreadID: threadID, historyID: HistoryID(history), internalDate: date,
        labelIDs: [GmailLabelID("INBOX")], snippet: "Synthetic snippet", sizeEstimate: 1_000,
        headers: MessageHeaderFields(
            subject: subject, from: EmailAddress(email: "zoo@list.example"), to: [EmailAddress(email: FakeCorpus.me.email)],
            cc: [], bcc: [], replyTo: [], date: date, messageID: "<\(id)@fake.example>", inReplyTo: nil, references: [],
            listUnsubscribe: nil, listUnsubscribePost: nil))],
        account: account, generation: 1)
    return try #require(try store.thread(account: account, gmailThreadID: threadID))
}

private final class CappedSearchStub: Sendable {
    let calls = Mutex<[(query: String, account: AccountID, maxResults: Int)]>([])
    let answer: [ThreadRef]

    init(_ answer: [ThreadRef]) {
        self.answer = answer
    }

    func search(_ query: String, _ account: AccountID, _ maxResults: Int) async throws -> [ThreadRef] {
        calls.withLock { $0.append((query, account, maxResults)) }
        return answer
    }
}

struct AskAdapterTests {
    @Test(.timeLimit(.minutes(1))) func searchOnceAnswersWithTheStoresHitsAndItsCoverage() async throws {
        let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 4, now: now))
        try put(store, account, id: "q1", subject: "Quokka budget", history: 9_001)
        try put(store, account, id: "q2", subject: "Quokka offsite", date: now.addingTimeInterval(-60), history: 9_002)
        let adapter = MailStoreAdapter(store: store)
        let once = try await adapter.searchOnce("quokka", semanticText: "the quokka offsite", accounts: [account], limit: 10)
        let live = try await firstValue(adapter.search("quokka", accounts: [account], limit: 10))
        #expect(once.hits.map(\.row.id) == live.hits.map(\.row.id), "the same hits as the live search")
        #expect(once.hits.count == 2 && once.hits.allSatisfy { !$0.matchedMessageRowIDs.isEmpty })
        #expect(once.completeness.reasons.contains { if case .olderMailNotLocal = $0 { true } else { false } },
                "no finished backfill: older mail may be missing")
        await #expect(throws: MailPortError.invalidQuery("check the search operators")) {
            _ = try await adapter.searchOnce("   ", semanticText: nil, accounts: nil, limit: 10)
        }
    }

    @Test(.timeLimit(.minutes(1))) func remoteSearchPassesTheCapAndMapsTheThreads() async throws {
        let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 3, now: now))
        let old = try put(store, account, id: "old1", subject: "Ledger from long ago",
                          date: now.addingTimeInterval(-86_400 * 900), history: 9_100)
        let stub = CappedSearchStub([old])
        let adapter = MailStoreAdapter(store: store, onDemand: .init(remoteSearchCapped: { query, account, maxResults in
            try await stub.search(query, account, maxResults)
        }))
        let found = try await adapter.remoteSearch(gmailQuery: " ledger ", account: account, maxResults: 20)
        #expect(found == [MailStoreAdapter.threadKey(old)])
        #expect(stub.calls.withLock { $0.map(\.query) } == ["ledger"])
        #expect(stub.calls.withLock { $0.map(\.maxResults) } == [20], "the caller's cap reaches Gmail's search")
        #expect(try await adapter.remoteSearch(gmailQuery: "  ", account: account, maxResults: 20).isEmpty)
        #expect(stub.calls.withLock { $0.count } == 1, "an empty query never reaches Gmail")

        let without = MailStoreAdapter(store: store)
        await #expect(throws: MailPortError.unsupported("Gmail search in this store")) {
            _ = try await without.remoteSearch(gmailQuery: "ledger", account: account, maxResults: 20)
        }
    }
}

@MainActor
@Suite(.serialized)
struct AskOlderMailWiringTests {
    @Test(.timeLimit(.minutes(2))) func olderMailReachesGmailWithReadsOnlyAndAsksForTwenty() async throws {
        let corpus = FakeCorpus.make(threadCount: 3, now: Date())
        let gmail = FakeGmail(accountEmail: corpus.account.email)
        await FakeGmailLaunch.seed(gmail, corpus: corpus)
        let starred = await gmail.deliver(subject: "Synthetic starred", labels: ["STARRED"])
        let store = try MailStore.openInMemoryForTesting()
        let running = try FakeGmailLaunch.makeSession(store: store, gmail: gmail,
                                                      unsubscribeTransport: nil)
        let app = AppModel(screen: .mail(running.session.environment), session: running.session)
        await running.session.start()
        let session = running.session
        defer { Task { await session.stop() } }
        let account = session.account
        await eventually("the inbox", timeout: .seconds(60)) {
            ((try? store.label(account: account, key: "INBOX"))?.totalThreads ?? 0) > 0
        }
        let adapter = try #require(session.environment.data as? MailStoreAdapter)
        let found = try await adapter.remoteSearch(gmailQuery: "is:starred", account: account, maxResults: 20)
        #expect(found.contains { $0.gmailThreadID.rawValue == starred.threadID })
        let lists = running.wire.requests.filter { $0.url.path(percentEncoded: false).hasSuffix("/messages") }
        #expect(lists.contains { ($0.url.query(percentEncoded: false) ?? "").contains("maxResults=20") })
        #expect(running.wire.requests.allSatisfy(isReadOnTheWire))
        _ = app
    }
}
