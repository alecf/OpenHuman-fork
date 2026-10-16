import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct BackgroundRefreshTests {
    private func syncedHarness(threads: Int = 3, clock: TestClock? = nil, gmail: FakeGmail? = nil) async throws -> EngineHarness {
        let h = try await EngineHarness(threads: threads, clock: clock, gmail: gmail)
        try await AccountSyncer(account: h.account, store: h.store, api: h.gmail, clock: h.clock).sync(reason: "launch")
        await h.gmail.resetAccounting()
        return h
    }

    private func queue(_ h: EngineHarness, _ engine: MailEngine, count: Int) async throws {
        for (index, thread) in h.threads.prefix(count).enumerated() {
            let ref = try h.ref(thread)
            let action: MailAction = switch index % 3 {
            case 0: .archive([ref])
            case 1: .star([ref])
            default: .markRead([ref])
            }
            _ = try await engine.perform(action, origin: .app)
        }
        #expect(try h.ops([.pending]).count == count)
    }

    @Test func refreshOnceRunsOneHistoryPassAndNeverBackfills() async throws {
        let h = try await syncedHarness()
        let arrived = await h.gmail.deliver(subject: "Synthetic arrival")
        let report = await h.engine().refreshOnce(deadline: h.clock.now.addingTimeInterval(30))

        #expect(await h.gmail.callCount(.listHistory) == 1)
        for method: GmailMethod in [.listMessages, .listThreads, .getLabel, .getProfile] {
            #expect(await h.gmail.callCount(method) == 0, "\(method.rawValue)")
        }
        #expect(report.syncs.map(\.kind) == ["incremental"])
        #expect(report.syncs.first?.error == nil)
        #expect(!report.deadlineReached && report.ownedElsewhere.isEmpty)
        #expect(try h.store.thread(account: h.account, gmailThreadID: GmailThreadID(arrived.threadID)) != nil)
        let status = try h.store.syncStatus(account: h.account)
        #expect(status.phase == .inboxReady)
        #expect(!status.backfillComplete)
        #expect(try h.store.lease(account: h.account) == nil, "the one-shot refresh hands its lease back")
    }

    @Test func theRefreshPassNeverSpawnsABackfill() async throws {
        let h = try await syncedHarness()
        let item = try #require(try h.store.accounts().first)
        let runtime = try #require(await h.engine().makeRuntime(item))

        let outcome = await runtime.refresh(until: h.clock.now.addingTimeInterval(30), maxOperations: 5)

        #expect(try outcome.sync?.get().kind == "incremental")
        #expect(await runtime.syncer.backfillTaskID == 0)
        await runtime.stop()
    }

    @Test func refreshOnceDrainsAtMostTheGivenNumberOfOperations() async throws {
        let h = try await syncedHarness(threads: 5)
        let engine = h.engine()
        try await queue(h, engine, count: 5)

        let report = await engine.refreshOnce(deadline: h.clock.now.addingTimeInterval(60), maxOperations: 2)

        let drained = try #require(report.operations[h.account])
        #expect(drained.claimed == 2 && drained.succeeded == 2)
        #expect(try h.ops([.succeeded]).count == 2)
        #expect(try h.ops([.pending]).count == 3)
        #expect(!(await h.serverLabels(ofThread: h.threads[0])).contains("INBOX"))
        #expect(await h.serverLabels(ofThread: h.threads[1]).contains("STARRED"))
        #expect(await h.serverLabels(ofThread: h.threads[2]).contains("UNREAD"))
        #expect(await h.serverLabels(ofThread: h.threads[3]).contains("INBOX"))
    }

    @Test func theDrainStopsBetweenOperationsOnceTheInjectedClockPassesTheDeadline() async throws {
        let h = try await syncedHarness()
        let engine = h.engine()
        try await queue(h, engine, count: 3)
        let clock = h.clock
        let deadline = clock.now.addingTimeInterval(30)
        await h.gmail.afterNext(.batchModify) { _ in clock.advance(to: deadline) }

        let report = await engine.refreshOnce(deadline: deadline)

        #expect(report.deadlineReached)
        let drained = try #require(report.operations[h.account])
        #expect(drained.succeeded == 1 && drained.released == 2)
        #expect(await h.gmail.callCount(.batchModify) == 1)
        #expect(try h.ops([.succeeded]).count == 1)
        #expect(try h.ops([.pending]).count == 2)
    }

    @Test func workThatRunsPastTheDeadlineSkipsTheDrain() async throws {
        let h = try await syncedHarness()
        let engine = h.engine()
        try await queue(h, engine, count: 2)
        let clock = h.clock
        await h.gmail.afterNext(.listHistory) { _ in clock.advance(by: .seconds(40)) }

        let report = await engine.refreshOnce(deadline: clock.now.addingTimeInterval(30))

        #expect(report.deadlineReached)
        #expect(report.operations[h.account] == nil)
        #expect(await h.gmail.callCount(.batchModify) == 0)
        #expect(try h.ops([.pending]).count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aHungGmailCallIsCancelledAtTheDeadline() async throws {
        let clock = TestClock(now: currentMinute())
        let deadline = clock.now.addingTimeInterval(25)
        let gmail = FakeGmail(accountEmail: "me@example.com", clock: TripwireClock(clock, tripsAt: deadline),
                              startDate: clock.now.addingTimeInterval(-86_400))
        let h = try await syncedHarness(clock: clock, gmail: gmail)
        let engine = h.engine()
        try await queue(h, engine, count: 1)
        let before = try h.store.syncStatus(account: h.account).historyID
        await gmail.latency(.listHistory, .seconds(1))

        let report = await engine.refreshOnce(deadline: deadline)

        #expect(report.deadlineReached)
        #expect(report.syncs.map(\.error) == ["cancelled"])
        #expect(report.operations[h.account] == nil)
        #expect(await gmail.callCount(.listHistory) == 1)
        #expect(try h.store.syncStatus(account: h.account).historyID == before)
        #expect(try h.ops([.pending]).count == 1)
    }

    @Test func aPassedDeadlineDoesNoWork() async throws {
        let h = try await syncedHarness()
        let report = await h.engine().refreshOnce(deadline: h.clock.now)
        #expect(report.deadlineReached)
        #expect(report.syncs.isEmpty)
        #expect(await h.gmail.callLog.isEmpty)
    }

    @Test func anAccountLeasedByAnotherLiveProcessIsSkipped() async throws {
        let h = try await syncedHarness()
        let other = OwnershipManager(store: h.store, identity: ProcessIdentity(writerID: "other-writer", pid: 1,
                                                                               host: "another-host"),
                                     kind: "cli", clock: h.clock)
        #expect(await other.acquire(h.account))

        let report = await h.engine().refreshOnce(deadline: h.clock.now.addingTimeInterval(30))

        #expect(report.ownedElsewhere == [h.account])
        #expect(report.syncs.isEmpty)
        #expect(await h.gmail.callLog.isEmpty)
    }

    @Test func theBackgroundEventPausesBackfillUntilTheAppIsActiveAgain() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        await engine.start()
        let runtime = try #require(await engine.runtime(for: h.account))

        await engine.handle(.didEnterBackground)
        #expect(await runtime.syncer.isBackfillPaused)
        #expect(await !runtime.syncer.isBackfillRunning)
        #expect(await !runtime.active)
        let spawned = await runtime.syncer.backfillTaskID

        let report = await engine.refreshOnce(deadline: h.clock.now.addingTimeInterval(30))
        #expect(report.syncs.count == 1 && report.syncs.first?.error == nil)
        #expect(await runtime.syncer.backfillTaskID == spawned)

        await engine.handle(.didBecomeActive)
        #expect(await !runtime.syncer.isBackfillPaused)
        #expect(await runtime.active)
        await engine.stop()
    }

    @Test(.timeLimit(.minutes(1))) func theBackgroundEventFlushesAPendingSendInsideItsUndoWindow() async throws {
        let h = try await EngineHarness()
        let system = TestSystemEvents()
        let engine = h.engine(systemEvents: system)
        var events = engine.events.makeAsyncIterator()
        let remote = try await h.gmail.createDraft(rawRFC822: rawDraft(subject: "Synthetic background send"), threadID: nil)
        let draft = try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(remote.id)))
        await engine.start()
        let receipt = try await engine.send(draft, authorization: .userConfirmed, undoWindow: .seconds(600))
        h.clock.advance(by: .seconds(120))
        #expect(try h.store.operation(receipt.sendOperationID)?.status == .pending)

        system.send(.didEnterBackground)
        while let event = await events.next() {
            if case .sent(draft, _) = event { break }
            if case .sendFailed(draft, let reason) = event {
                Issue.record("send failed: \(reason)")
                break
            }
        }

        #expect(h.clock.now < receipt.sendAfter, "sent before the undo window ended")
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        try await h.expectOneCleanSentMessage("background flush")
        await engine.stop()
    }

    @Test func phoneWindowDefaultsAreEngineConfiguration() async throws {
        #expect(LocalWindow.phone == LocalWindow(metadataHorizonDays: 365, bodyHorizonDays: 30, downloadBodies: false,
                                                 backfillUnitsPerMinute: 1_500))
        #expect(LocalWindow.standard == LocalWindow(metadataHorizonDays: nil, bodyHorizonDays: 90, downloadBodies: true))
        #if os(macOS)
        #expect(LocalWindow.platformDefault == .standard)
        #endif
        let h = try await EngineHarness(threads: 0)

        let mac = await h.engine().runtimeEnvironment()
        #expect(mac.syncSettings.metadataHorizon == nil)
        #expect(mac.syncSettings.bodyHorizon == .seconds(90 * 86_400))
        #expect(mac.syncSettings.backfillUnitsPerMinute == engineGmailConfig.unitsPerMinute / 2)
        #expect(AccountRuntime.bodyPolicy(h.store, downloadBodies: mac.downloadBodies).enabled)

        let phone = MailEngine(store: h.store, gmailFactory: h.factory, tokenStore: nil, oauthClient: nil,
                               configuration: EngineConfiguration(role: .app, appVersion: "0.0.0-test",
                                                                  gmail: engineGmailConfig, clock: h.clock,
                                                                  window: .phone),
                               systemEvents: nil)
        let env = await phone.runtimeEnvironment()
        #expect(env.syncSettings.metadataHorizon == .seconds(365 * 86_400))
        #expect(env.syncSettings.bodyHorizon == .seconds(30 * 86_400))
        #expect(env.syncSettings.backfillUnitsPerMinute == 1_500)
        #expect(!AccountRuntime.bodyPolicy(h.store, downloadBodies: env.downloadBodies).enabled)
        #expect(try h.store.setting(.bodyHorizonDays, scope: .global) == 90, "the defaults are not written to the store")

        try h.store.setSetting(.bodyHorizonDays, 60, scope: .global)
        try h.store.setSetting(.metadataHorizonDays, 730, scope: .global)
        try h.store.setSetting(.downloadBodies, true, scope: .global)
        let chosen = await phone.runtimeEnvironment()
        #expect(chosen.syncSettings.bodyHorizon == .seconds(60 * 86_400))
        #expect(chosen.syncSettings.metadataHorizon == .seconds(730 * 86_400))
        #expect(AccountRuntime.bodyPolicy(h.store, downloadBodies: chosen.downloadBodies).enabled)
    }
}

private final class TripwireClock: OHClock {
    let base: TestClock
    let trip: Date

    init(_ base: TestClock, tripsAt trip: Date) {
        self.base = base
        self.trip = trip
    }

    var now: Date { base.now }

    func sleep(until deadline: Date) async throws {
        base.advance(to: trip)
        try await base.sleep(until: .distantFuture)
    }
}
