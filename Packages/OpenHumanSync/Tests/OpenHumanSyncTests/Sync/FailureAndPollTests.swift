import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct FailureAndPollTests {
    @Test func failuresAreCountedLoggedAndClearedBySuccess() async throws {
        let h = try SyncHarness()
        await h.gmail.seedInbox(count: 2)
        try await h.syncer.sync(reason: "launch")
        await h.gmail.failNext(.listHistory, with: .server(status: 503, message: "backend detail"), count: 2)
        for _ in 0..<2 {
            await #expect(throws: GmailError.server(status: 503, message: "backend detail")) {
                try await h.syncer.sync(reason: "poll")
            }
        }
        var status = try h.status()
        #expect(status.consecutiveFailures == 2 && status.lastError == "server_503")
        let failed = try h.store.syncLog(account: h.account, limit: 1).first
        #expect(failed?.outcome == "error" && failed?.errorCode == "server_503" && failed?.kind == "incremental")
        try await h.syncer.sync(reason: "poll")
        status = try h.status()
        #expect(status.consecutiveFailures == 0 && status.lastError == nil && status.lastSuccessAt != nil)
    }

    @Test func reauthRequiredMarksTheAccountAndStopsPolling() async throws {
        let h = try SyncHarness()
        await h.gmail.failNext(.getProfile, with: .reauthRequired)
        let loop = SyncLoop(syncer: h.syncer, store: h.store, clock: h.clock)
        await loop.start()
        try await eventually("loop stopped") { await loop.state == .stoppedNeedsReauth }
        #expect(try h.store.accounts().first?.status == .needsReauth)
        let failed = await loop.failedRuns, runs = await h.syncer.runCount
        #expect(failed == 1 && runs == 1)
    }

    @Test func pollScheduleBacksOffExponentiallyToFifteenMinutes() {
        let base = Duration.seconds(60)
        #expect([0, 1, 2, 3, 4, 5, 9].map { PollSchedule.delay(base: base, consecutiveFailures: $0) }
                == [60, 120, 240, 480, 900, 900, 900].map { Duration.seconds($0) })
    }

    @Test func pollsEverySixtySecondsBacksOffOnFailureAndRunsWhenPoked() async throws {
        let clock = TestClock(now: testNow)
        let h = try SyncHarness(clock: clock)
        await h.gmail.seedInbox(count: 2)
        let loop = SyncLoop(syncer: h.syncer, store: h.store, clock: clock)
        await loop.start()
        try await eventually("initial sync") { await loop.completedRuns == 1 && clock.sleeperCount == 1 }
        #expect(clock.nextDeadline == clock.now.addingTimeInterval(60))

        let (message, _) = await h.gmail.deliver(subject: "Arrives between polls")
        clock.advance(by: .seconds(60))
        try await eventually("second poll") { await loop.completedRuns == 2 && clock.sleeperCount == 1 }
        #expect(try h.message(message) != nil)

        await h.gmail.failNext(.listHistory, with: .server(status: 500, message: nil))
        clock.advance(by: .seconds(60))
        try await eventually("failed poll") { await loop.failedRuns == 1 && clock.sleeperCount == 1 }
        #expect(await loop.lastDelay == .seconds(120))
        #expect(clock.nextDeadline == clock.now.addingTimeInterval(120))

        clock.advance(by: .seconds(120))
        try await eventually("recovered") { await loop.completedRuns == 3 && clock.sleeperCount == 1 }
        #expect(await loop.lastDelay == .seconds(60))

        let (poked, _) = await h.gmail.deliver(subject: "Sync now")
        await loop.poke()
        try await eventually("poked run") { await loop.completedRuns == 4 && clock.sleeperCount == 1 }
        #expect(try h.message(poked) != nil)
        await loop.stop()
        try await eventually("stopped") { await loop.state == .stopped }
    }

    @Test func transientServerErrorsAreRetriedBelowTheSyncer() async throws {
        let clock = InstantClock(now: testNow)
        var wire: FakeGmailTransport?
        let metrics = SyncMetricsCollector()
        let h = try SyncHarness(clock: clock) { gmail in
            let transport = FakeGmailTransport(gmail)
            wire = transport
            return GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(),
                               transport: ReadOnlyTransport(wrapping: transport),
                               config: GmailClientConfig(userAgent: "OpenHumanMail/test"), clock: clock, metrics: metrics)
        }
        await h.gmail.seedInbox(count: 3)
        await h.gmail.failNext(.listThreads, with: .server(status: 503, message: nil), count: 2)
        await h.gmail.failNext(.getThread, with: .rateLimited(retryAfter: .seconds(5)))
        try await h.syncer.sync(reason: "launch")
        #expect(try h.inbox().count == 3 && (try h.status()).consecutiveFailures == 0)
        #expect(clock.sleeps.contains(5))
        #expect(try #require(wire).nonGETRequests.isEmpty)
        #expect(metrics.snapshot.requests == metrics.snapshot.calls + 3)
    }
}
