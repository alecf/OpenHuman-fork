import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Synchronization
import Testing
@testable import OpenHumanGmail

final class ManualClock: OHClock {
    private struct Sleeper { var id: Int; var deadline: Date; var continuation: CheckedContinuation<Void, any Error> }
    private struct State { var now: Date; var sleepers: [Sleeper] = []; var nextID = 0 }
    private let state: Mutex<State>

    init(now: Date = Date(timeIntervalSince1970: 1_790_000_000)) { state = Mutex(State(now: now)) }

    var now: Date { state.withLock { $0.now } }

    func sleep(until deadline: Date) async throws {
        try Task.checkCancellation()
        let id = state.withLock { s -> Int in s.nextID += 1; return s.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready: Bool = state.withLock { s in
                    if deadline <= s.now { return true }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { s -> Sleeper? in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    @discardableResult func advanceToNextDeadline() -> Bool {
        let due: Sleeper? = state.withLock { s in
            guard let index = s.sleepers.indices.min(by: { s.sleepers[$0].deadline < s.sleepers[$1].deadline }) else { return nil }
            let sleeper = s.sleepers.remove(at: index)
            if sleeper.deadline > s.now { s.now = sleeper.deadline }
            return sleeper
        }
        due?.continuation.resume()
        return due != nil
    }
}

@Suite struct QuotaLimiterPriorityTests {
    private func drive(_ clock: ManualClock, until finished: () async -> Bool) async {
        for _ in 0..<1000 {
            for _ in 0..<200 { await Task.yield() }
            if await finished() { return }
            clock.advanceToNextDeadline()
        }
        Issue.record("did not finish")
    }

    private func waitUntilQueued(_ limiter: QuotaLimiter, _ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            if await limiter.waiting >= count { return }
            await Task.yield()
        }
        Issue.record("only \(await limiter.waiting) of \(count) requests queued")
    }

    @Test func slotsGoToTheHighestPriorityFirstAndFIFOWithin() async throws {
        let clock = InstantClock()
        let limiter = QuotaLimiter(unitsPerMinute: 6_000_000, maxConcurrent: 1, clock: clock)
        try await limiter.acquire(units: 1, priority: .sync)
        var tasks: [Task<Void, Error>] = []
        for (mark, priority) in [(2, RequestPriority.backfill), (3, .sync), (4, .interactive), (5, .sync), (6, .queue)] {
            tasks.append(Task { try await limiter.acquire(units: mark, priority: priority); await limiter.release() })
            await waitUntilQueued(limiter, tasks.count)
        }
        await limiter.release()
        for task in tasks { try await task.value }
        #expect(await limiter.chargedUnits == [1, 4, 6, 3, 5, 2])
    }

    @Test func tokensGoToTheHighestPriorityFirst() async throws {
        let clock = ManualClock()
        let limiter = QuotaLimiter(unitsPerMinute: 6_000, maxConcurrent: 8, clock: clock)
        try await limiter.acquire(units: 1500, priority: .sync)
        await limiter.release()
        let done = Mutex(0)
        var tasks: [Task<Void, Error>] = []
        for (mark, priority) in [(101, RequestPriority.sync), (102, .queue), (103, .sync)] {
            tasks.append(Task {
                try await limiter.acquire(units: mark, priority: priority)
                await limiter.release()
                done.withLock { $0 += 1 }
            })
            await waitUntilQueued(limiter, tasks.count)
        }
        await drive(clock) { done.withLock { $0 } == 3 }
        #expect(await limiter.chargedUnits == [1500, 102, 101, 103])
    }

    @Test func backfillUsesTheBucketOnlyAboveHalfCapacity() async throws {
        let clock = InstantClock()
        let start = clock.now
        let limiter = QuotaLimiter(unitsPerMinute: 6_000, maxConcurrent: 8, clock: clock)
        try await limiter.acquire(units: 900, priority: .backfill)
        await limiter.release()
        try await limiter.acquire(units: 500, priority: .sync)
        await limiter.release()
        #expect(clock.now == start)
        try await limiter.acquire(units: 10, priority: .backfill)
        await limiter.release()
        #expect(clock.now.timeIntervalSince(start) >= 6.5)
        #expect(clock.now.timeIntervalSince(start) < 6.6)
    }

    @Test func syncIsNotBlockedByAWaitingBackfill() async throws {
        let clock = InstantClock()
        let limiter = QuotaLimiter(unitsPerMinute: 6_000, maxConcurrent: 8, clock: clock)
        try await limiter.acquire(units: 1000, priority: .sync)
        await limiter.release()
        let backfill = Task { try await limiter.acquire(units: 10, priority: .backfill); await limiter.release() }
        await waitUntilQueued(limiter, 1)
        try await limiter.acquire(units: 100, priority: .sync)
        await limiter.release()
        try await backfill.value
        #expect(await limiter.chargedUnits == [1000, 100, 10])
    }

    @Test func interactiveJumpsTheQueueAndNeverWaitsPastTwoSeconds() async throws {
        let clock = ManualClock()
        let limiter = QuotaLimiter(unitsPerMinute: 6_000, maxConcurrent: 8, clock: clock)
        try await limiter.acquire(units: 1500, priority: .sync)
        await limiter.release()
        let start = clock.now
        let sync = Task { try await limiter.acquire(units: 301, priority: .sync); await limiter.release() }
        await waitUntilQueued(limiter, 1)
        let finished = Mutex(false)
        let interactive = Task {
            try await limiter.acquire(units: 302, priority: .interactive)
            await limiter.release()
            finished.withLock { $0 = true }
        }
        await waitUntilQueued(limiter, 2)
        await drive(clock) { finished.withLock { $0 } }
        #expect(abs(clock.now.timeIntervalSince(start) - 2) < 0.01)
        try await interactive.value
        await drive(clock) { await limiter.waiting == 0 }
        try await sync.value
        #expect(await limiter.chargedUnits == [1500, 302, 301])
    }

    @Test func aRateLimitPausesEverythingBelowInteractive() async throws {
        let clock = InstantClock()
        let start = clock.now
        let limiter = QuotaLimiter(unitsPerMinute: 6_000, maxConcurrent: 8, clock: clock)
        let queued = Task { try await limiter.acquire(units: 1, priority: .queue); await limiter.release() }
        try await queued.value
        await limiter.noteRateLimited(retryAfter: .seconds(20))
        let backfill = Task { try await limiter.acquire(units: 1, priority: .backfill); await limiter.release() }
        let sync = Task { try await limiter.acquire(units: 1, priority: .sync); await limiter.release() }
        try await backfill.value
        try await sync.value
        #expect(clock.now.timeIntervalSince(start) >= 20)
    }

    @Test func cancellingAWaiterFreesItsPlace() async throws {
        let clock = InstantClock()
        let limiter = QuotaLimiter(unitsPerMinute: 6_000_000, maxConcurrent: 1, clock: clock)
        try await limiter.acquire(units: 1, priority: .sync)
        let waiter = Task { try await limiter.acquire(units: 5, priority: .sync) }
        await waitUntilQueued(limiter, 1)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await limiter.waiting == 0)
        await limiter.release()
        #expect(await limiter.connectionsInUse == 0)
        try await limiter.acquire(units: 2, priority: .sync)
        await limiter.release()
        #expect(await limiter.chargedUnits == [1, 2])
    }
}
