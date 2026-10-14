import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct SnoozeRunnerTests {
    private func snoozeCache(_ h: EngineHarness, _ thread: String) throws -> SnoozeInfo? {
        guard let ref = try h.store.thread(account: h.account, gmailThreadID: GmailThreadID(thread)) else { return nil }
        return try h.store.threadDetail(ref.rowID)?.snooze
    }

    @Test func wakesAtTheMinutePlusJitterAtTheTopOfTheInbox() async throws {
        let h = try await EngineHarness()
        let thread = h.threads[0]
        let wake = h.clock.now.addingTimeInterval(600)
        let stamp = await h.snoozeOnServer(thread, until: wake)
        let engine = h.engine()
        await engine.setTestSeams(jitter: .seconds(7))
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        _ = try await engine.syncNow(h.account, reason: "test")
        try await eventually("snooze cached") { try snoozeCache(h, thread)?.wakeAt == wake }
        let scheduler = try #require(await engine.scheduler(for: h.account))

        h.clock.advance(to: wake.addingTimeInterval(6))
        try await eventually("armed for wake + jitter") { await scheduler.nextFire == wake.addingTimeInterval(7) }
        #expect(events.snoozesWoken.isEmpty)
        #expect(await h.gmail.callCount(.batchModify) == 0)

        h.clock.advance(to: wake.addingTimeInterval(7))
        try await eventually("woken on Gmail") { (await h.serverLabels(ofThread: thread)).contains("INBOX") }
        let labels = await h.serverLabels(ofThread: thread)
        #expect(labels.contains("UNREAD"))
        #expect(!labels.contains(try #require(await h.gmail.labelID(named: stamp))))
        #expect(!labels.contains(try #require(await h.gmail.labelID(named: OHGmailLabels.snoozed))))
        try await eventually("woke event") { events.snoozesWoken.count == 1 }
        #expect(events.snoozesWoken.first?.1 == .seconds(7))
        #expect(try h.inbox().first == thread)
        try await eventually("cache cleared") { try snoozeCache(h, thread) == nil }
        await engine.stop()
    }

    @Test func twoInstallsDueTogetherWakeOnce() async throws {
        let a = try await EngineHarness()
        let b = try await EngineHarness(threads: 0, clock: a.clock, gmail: a.gmail)
        let thread = a.threads[1]
        let wake = a.clock.now.addingTimeInterval(600)
        _ = await a.snoozeOnServer(thread, until: wake)
        let engineA = a.engine(), engineB = b.engine()
        await engineA.setTestSeams(jitter: .seconds(2))
        await engineB.setTestSeams(jitter: .seconds(9))
        await engineA.start()
        await engineB.start()
        try await a.waitForSyncs(engineA)
        try await b.waitForSyncs(engineB)
        _ = try await engineA.syncNow(a.account, reason: "test")
        _ = try await engineB.syncNow(b.account, reason: "test")
        try await eventually("both cached") {
            try snoozeCache(a, thread)?.wakeAt == wake && snoozeCache(b, thread)?.wakeAt == wake
        }

        a.clock.advance(to: wake.addingTimeInterval(2))
        try await eventually("A woke it") { (await a.serverLabels(ofThread: thread)).contains("INBOX") }
        let schedulerB = try #require(await engineB.scheduler(for: b.account))
        let passes = await schedulerB.passes
        a.clock.advance(to: wake.addingTimeInterval(9))
        try await eventually("B passed and saw the wake") {
            let passed = await schedulerB.passes > passes
            let idle = await schedulerB.nextFire != nil
            return try passed && idle && snoozeCache(b, thread) == nil
        }
        #expect(await a.gmail.callCount(.batchModify) == 1)
        #expect(try b.store.operations(account: b.account, statuses: [], limit: 50).filter { $0.origin == .scheduler }.isEmpty)
        await engineA.stop()
        await engineB.stop()
    }

    @Test func aRescheduleBetweenTheHistoryCheckAndTheActionIsCaughtByTheResourceCheck() async throws {
        let h = try await EngineHarness()
        let thread = h.threads[2]
        let start = h.clock.now
        let wake = start.addingTimeInterval(60)
        _ = await h.snoozeOnServer(thread, until: wake)
        let engine = h.engine()
        await engine.setTestSeams(jitter: .seconds(30))
        await engine.start()
        try await h.waitForSyncs(engine)
        _ = try await engine.syncNow(h.account, reason: "test")
        try await eventually("cached") { try snoozeCache(h, thread)?.wakeAt == wake }
        h.clock.advance(to: start.addingTimeInterval(60))
        try await h.waitForSyncs(engine, 3)
        let scheduler = try #require(await engine.scheduler(for: h.account))
        try await eventually("armed") { await scheduler.nextFire == wake.addingTimeInterval(30) }

        let later = start.addingTimeInterval(3_600)
        let laterStamp = ScheduleLabel(kind: .snoozed, due: later).name
        let laterID = await h.gmail.addUserLabel(laterStamp)
        let oldID = try #require(await h.gmail.labelID(named: ScheduleLabel(kind: .snoozed, due: wake).name))
        let messages = await h.gmail.messageIDs(inThread: thread)
        await h.gmail.afterNext(.listHistory) { gmail in
            for message in messages { gmail.modifyLabels(messageID: message, add: [laterID], remove: [oldID]) }
        }
        h.clock.advance(to: wake.addingTimeInterval(30))
        try await eventually("rescheduled in the cache") { try snoozeCache(h, thread)?.wakeAt == later }
        #expect(await h.gmail.callCount(.batchModify) == 0)
        #expect(!(await h.serverLabels(ofThread: thread)).contains("INBOX"))
        await engine.stop()
    }

    @Test func newMailIntoASnoozedThreadClearsTheSnooze() async throws {
        let h = try await EngineHarness()
        let thread = h.threads[0]
        let stamp = await h.snoozeOnServer(thread, until: h.clock.now.addingTimeInterval(86_400))
        let engine = h.engine()
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        _ = try await engine.syncNow(h.account, reason: "test")
        try await eventually("cached") { try snoozeCache(h, thread) != nil }
        await h.gmail.deliver(subject: "Re: Seeded thread 0", body: "Synthetic reply.", threadID: thread)
        _ = try await engine.syncNow(h.account, reason: "test")
        try await eventually("snooze labels removed on Gmail") {
            !(await h.serverLabels(ofThread: thread)).contains(try #require(await h.gmail.labelID(named: stamp)))
        }
        #expect(!(await h.serverLabels(ofThread: thread)).contains(try #require(await h.gmail.labelID(named: OHGmailLabels.snoozed))))
        #expect(events.snoozesWoken.isEmpty)
        let scheduled = try h.ops().filter { $0.origin == .scheduler }
        #expect(scheduled.count == 1)
        if case let .modifyLabels(_, add, _, _)? = scheduled.first?.payload { #expect(add.isEmpty) }
        await engine.stop()
    }

    @Test func notComposedOrSwitchedOffNothingWakes() async throws {
        for variant in ["composition", "setting"] {
            let h = try await EngineHarness()
            let thread = h.threads[0]
            let wake = h.clock.now.addingTimeInterval(120)
            _ = await h.snoozeOnServer(thread, until: wake)
            let engine = variant == "composition" ? h.engine(schedulers: [.reminder]) : h.engine()
            if variant == "setting" { try h.store.setSetting(.schedulerSnoozeEnabled, false, scope: .global) }
            await engine.setTestSeams(jitter: .zero)
            await engine.start()
            try await h.waitForSyncs(engine)
            _ = try await engine.syncNow(h.account, reason: "test")
            try await eventually("cached (\(variant))") { try snoozeCache(h, thread)?.wakeAt == wake }
            h.clock.advance(to: wake.addingTimeInterval(600))
            try await h.waitForSyncs(engine, 3)
            try await h.waitForSchedulerIdle(engine, passes: 2)
            #expect(try snoozeCache(h, thread)?.wakeAt == wake, "\(variant)")
            #expect(await h.gmail.callCount(.batchModify) == 0, "\(variant)")
            await engine.stop()
        }
    }
}
