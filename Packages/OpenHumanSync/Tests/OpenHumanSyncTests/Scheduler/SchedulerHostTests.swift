import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanSync

private final class StandInRunner: ScheduleRunner {
    struct Broken: Error {}
    let kind: ScheduleKind
    let fails: Bool
    let alwaysDue: Bool
    private let count = Mutex(0)
    init(_ kind: ScheduleKind, fails: Bool = false, alwaysDue: Bool = false) {
        self.kind = kind
        self.fails = fails
        self.alwaysDue = alwaysDue
    }
    var calls: Int { count.withLock { $0 } }
    func nextDue(account: AccountID, now: Date) async throws -> Date? { alwaysDue ? now : nil }
    func reconcile(account: AccountID, now: Date) async throws {
        count.withLock { $0 += 1 }
        if fails { throw Broken() }
    }
}

private final class SlowDueRunner: ScheduleRunner {
    let kind = ScheduleKind.reminder
    private let state = Mutex<(calls: Int, gate: Gate?)>((0, nil))
    var calls: Int { state.withLock { $0.calls } }
    func holdNextDue() -> Gate {
        let gate = Gate()
        state.withLock { $0.gate = gate }
        return gate
    }
    func nextDue(account: AccountID, now: Date) async throws -> Date? {
        if let gate = state.withLock({ s -> Gate? in defer { s.gate = nil }; return s.gate }) { await gate.pass() }
        return nil
    }
    func reconcile(account: AccountID, now: Date) async throws { state.withLock { $0.calls += 1 } }
}

private final class Emitted: Sendable {
    let events = Mutex<[EngineEvent]>([])
    var degraded: [(ScheduleKind, String)] {
        events.withLock { $0 }.compactMap { if case let .schedulerDegraded(k, r) = $0 { return (k, r) } else { return nil } }
    }
}

@Suite struct SchedulerHostTests {
    @Test func aFailingRunnerIsSuspendedWithBackoffAndTheOthersGoOn() async throws {
        let clock = TestClock(now: currentMinute())
        let broken = StandInRunner(.snooze, fails: true, alwaysDue: true)
        let healthy = StandInRunner(.reminder)
        let emitted = Emitted()
        let host = Scheduler(account: AccountID(1), runners: [healthy, broken], clock: clock, isEnabled: { _ in true },
                             emit: { event in emitted.events.withLock { $0.append(event) } })
        let start = clock.now
        await host.start()
        for failure in 1...3 {
            try await eventually("failure \(failure)") {
                let idle = await host.nextFire != nil
                return broken.calls == failure && idle
            }
            if failure < 3 { clock.advance(by: Scheduler.retryWhileDue) }
        }
        #expect(emitted.degraded.count == 1)
        #expect(emitted.degraded.first?.0 == .snooze)
        #expect(emitted.degraded.first?.1.contains("suspended for 15 min") == true)
        let suspendedAt = start.addingTimeInterval(120)
        #expect(await host.health[.snooze]?.suspendedUntil == suspendedAt.addingTimeInterval(900))
        #expect(await host.nextFire == suspendedAt.addingTimeInterval(900))

        let healthyCalls = healthy.calls
        await host.poke()
        try await eventually("healthy runner ran") {
                let idle = await host.nextFire != nil
                return healthy.calls > healthyCalls && idle
            }
        #expect(broken.calls == 3)

        clock.advance(to: suspendedAt.addingTimeInterval(900))
        for failure in 4...6 {
            try await eventually("failure \(failure)") {
                let idle = await host.nextFire != nil
                return broken.calls == failure && idle
            }
            if failure < 6 { clock.advance(by: Scheduler.retryWhileDue) }
        }
        #expect(emitted.degraded.count == 2)
        #expect(emitted.degraded.last?.1.contains("suspended for 30 min") == true)
        await host.stop()
    }

    @Test func aRunnerSwitchedOffAtRuntimeIsNeverCalled() async throws {
        let clock = TestClock(now: currentMinute())
        let off = StandInRunner(.sendLater, alwaysDue: true)
        let on = StandInRunner(.reminder)
        let host = Scheduler(account: AccountID(1), runners: [on, off], clock: clock,
                             isEnabled: { $0 != .sendLater }, emit: { _ in })
        await host.start()
        try await eventually("first pass") {
                let idle = await host.nextFire != nil
                return on.calls == 1 && idle
            }
        #expect(await host.nextFire == clock.now.addingTimeInterval(Scheduler.maxNap.timeInterval))
        await host.poke()
        try await eventually("second pass") { on.calls == 2 }
        #expect(off.calls == 0)
        await host.stop()
    }

    @Test func aPokeWhileTheNextWakeIsComputedIsNotLost() async throws {
        let clock = TestClock(now: currentMinute())
        let slow = SlowDueRunner()
        let host = Scheduler(account: AccountID(1), runners: [slow], clock: clock, isEnabled: { _ in true }, emit: { _ in })
        let gate = slow.holdNextDue()
        await host.start()
        try await eventually("first pass reading its next due time") { slow.calls == 1 && gate.reached }
        await host.poke()
        gate.open()
        try await eventually("the poke ran a second pass") {
            let idle = await host.nextFire != nil
            return slow.calls == 2 && idle
        }
        await host.stop()
    }

    @Test func aBrokenSnoozeRunnerDoesNotStopRemindersOrTheDrainer() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        let broken = StandInRunner(.snooze, fails: true, alwaysDue: true)
        await engine.setTestSeams(runnerOverride: { kind, _ in kind == .snooze ? broken : nil })
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        let scheduler = try #require(await engine.scheduler(for: h.account))
        try await eventually("first failure") {
                let idle = await scheduler.nextFire != nil
                return broken.calls >= 1 && idle
            }
        for _ in 0..<6 {
            if broken.calls >= Scheduler.failuresBeforeSuspension { break }
            let calls = broken.calls
            h.clock.advance(by: Scheduler.retryWhileDue)
            try await eventually("another pass") {
                let idle = await scheduler.nextFire != nil
                return broken.calls > calls && idle
            }
        }
        try await eventually("degraded") { !events.degraded.isEmpty }
        #expect(events.degraded.first?.0 == .snooze)

        let thread = h.threads[0]
        let done = try await engine.perform(.archive([try h.ref(thread)]), origin: .app)
        try await eventually("Mark done drained") { try h.store.operation(done.operationIDs[0])?.status == .succeeded }
        let due = h.clock.now.addingTimeInterval(300)
        _ = try await engine.perform(.setReminder(try h.ref(thread), dueAt: due, condition: .always), origin: .app)
        h.clock.advance(to: due)
        try await eventually("reminder fired") { events.remindersFired.count == 1 }
        try await eventually("back in the inbox on Gmail") { (await h.serverLabels(ofThread: thread)).contains("INBOX") }
        await engine.stop()
    }
}
