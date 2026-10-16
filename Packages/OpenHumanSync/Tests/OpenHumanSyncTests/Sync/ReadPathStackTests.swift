import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct ReadPathStackTests {
    @Test func syncResyncAndBodiesSendOnlyGETsThroughTheLiveStack() async throws {
        let clock = InstantClock(now: testNow)
        let metrics = SyncMetricsCollector()
        var wireBox: FakeGmailTransport?
        var factoryBox: DefaultGmailClientFactory?
        let h = try SyncHarness(clock: clock, onDisk: true) { gmail in
            let wire = FakeGmailTransport(gmail)
            let factory = DefaultGmailClientFactory(apiTransport: wire,
                                                    config: GmailClientConfig(userAgent: "OpenHumanMail/test"),
                                                    clock: clock, metrics: { _ in metrics }) { _ in
                (StaticTokenProvider(), [GmailScope.modify])
            }
            wireBox = wire
            factoryBox = factory
            return try! factory.client(for: "me@example.com")
        }
        let wire = try #require(wireBox), factory = try #require(factoryBox)

        let threads = await h.gmail.seedInbox(count: 12)
        await h.gmail.deliver(subject: "Re", threadID: threads[3])
        try await h.syncer.sync(reason: "launch")
        await h.gmail.simulateWebArchive(threadID: threads[0])
        await h.gmail.deliver(subject: "Delta")
        try await h.syncer.sync(reason: "poll")
        await h.gmail.expireAllHistory()
        let resync = try await h.syncer.sync(reason: "poll")
        #expect(resync.kind == "full_resync")
        let ref = try #require(try h.store.thread(account: h.account, gmailThreadID: GmailThreadID(threads[3])))
        let fetcher = BodyFetcher(account: h.account, store: h.store, api: try factory.client(for: "me@example.com"))
        _ = try await fetcher.ensureBodies(thread: ref.rowID)

        #expect(try h.inbox() == (try await h.serverInbox()))
        #expect(!wire.requests.isEmpty && wire.nonGETRequests.isEmpty)
        #expect(wire.requests.allSatisfy { $0.headers["Authorization"] == "Bearer test-access-token" })
        #expect(metrics.snapshot.units > 0)
        #expect(try h.store.syncLog(account: h.account, limit: 10).allSatisfy { $0.quotaUnits >= 0 })
    }

    @Test func theBackfillAndRemoteSearchSendOnlyGETsThroughTheLiveStack() async throws {
        let clock = InstantClock(now: testNow)
        let metrics = SyncMetricsCollector()
        var wireBox: FakeGmailTransport?
        var apiBox: (any GmailAPI)?
        let h = try SyncHarness(settings: backfillSettings(pageSize: 100), clock: clock) { gmail in
            let wire = FakeGmailTransport(gmail)
            let factory = DefaultGmailClientFactory(apiTransport: wire,
                                                    config: GmailClientConfig(userAgent: "OpenHumanMail/test"),
                                                    clock: clock, metrics: { _ in metrics }) { _ in
                (StaticTokenProvider(), [GmailScope.modify])
            }
            wireBox = wire
            let api = try! factory.client(for: "me@example.com")
            apiBox = api
            return api
        }
        let wire = try #require(wireBox), api = try #require(apiBox)
        let seeded = await h.gmail.seedMailbox(count: 200, end: testNow.addingTimeInterval(-3_600))
        _ = try await h.gmail.createDraft(rawRFC822: rawDraft(subject: "Agent reply", headers: ["X-OpenHuman-Origin": "agent"]),
                                          threadID: nil)
        try await h.syncer.sync(reason: "launch")
        #expect(await h.syncer.runBackfill() == .complete)
        let found = try await RemoteSearch(account: h.account, store: h.store, api: api).search(gmailQuery: "is:starred")
        #expect(found.count == seeded.starred.count)

        #expect(!wire.requests.isEmpty && !wire.batchRequests.isEmpty)
        #expect(wire.requests.allSatisfy { $0.method == "GET" || ($0.method == "POST" && $0.url.path().hasPrefix("/batch/")) })
        #expect(wire.nonGETRequests.isEmpty)
        let serverMessages = try await serverMessageIDs(h.gmail)
        #expect(try h.localMessages(among: serverMessages) == serverMessages)
        #expect(try h.status().backfillComplete)
    }
}
