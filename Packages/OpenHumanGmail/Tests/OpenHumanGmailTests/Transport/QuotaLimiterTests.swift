import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

@Suite struct QuotaLimiterTests {
    @Test func burstThenRefillWait() async throws {
        let clock = InstantClock()
        let limiter = QuotaLimiter(unitsPerMinute: 600, maxConcurrent: 8, clock: clock)
        for _ in 0..<15 {
            try await limiter.acquire(units: 10, priority: .sync)
            await limiter.release()
        }
        #expect(clock.sleeps.isEmpty)
        try await limiter.acquire(units: 10, priority: .sync)
        await limiter.release()
        #expect(abs((clock.sleeps.last ?? 0) - 1.0) < 0.01)
        #expect(await limiter.unitsUsed(since: .distantPast) == 160)
    }

    @Test func requestLargerThanCapacityDoesNotDeadlock() async throws {
        let clock = InstantClock()
        let limiter = QuotaLimiter(unitsPerMinute: 60, maxConcurrent: 8, clock: clock)
        try await limiter.acquire(units: 100, priority: .backfill)
        await limiter.release()
        #expect(await limiter.unitsUsed(since: .distantPast) == 100)
    }

    @Test func connectionCapQueuesFIFO() async throws {
        let clock = InstantClock()
        let limiter = QuotaLimiter(unitsPerMinute: 60_000, maxConcurrent: 2, clock: clock)
        try await limiter.acquire(units: 1, priority: .sync)
        try await limiter.acquire(units: 1, priority: .sync)
        let third = Task { try await limiter.acquire(units: 1, priority: .sync); return true }
        for _ in 0..<50 { await Task.yield() }
        #expect(await limiter.connectionsInUse == 2)
        await limiter.release()
        #expect(try await third.value)
        #expect(await limiter.connectionsInUse == 2)
        await limiter.release()
        await limiter.release()
        #expect(await limiter.connectionsInUse == 0)
    }

    @Test func rateLimitPausesBackgroundButNotInteractive() async throws {
        let clock = InstantClock()
        let start = clock.now
        let limiter = QuotaLimiter(unitsPerMinute: 6000, maxConcurrent: 8, clock: clock)
        await limiter.noteRateLimited(retryAfter: .seconds(30))
        try await limiter.acquire(units: 1, priority: .interactive)
        await limiter.release()
        #expect(clock.now.timeIntervalSince(start) < 1)
        try await limiter.acquire(units: 1, priority: .sync)
        await limiter.release()
        #expect(clock.now.timeIntervalSince(start) >= 30)
    }

    @Test func interactiveWaitsAtMostTwoSeconds() async throws {
        let clock = InstantClock()
        let start = clock.now
        let limiter = QuotaLimiter(unitsPerMinute: 60, maxConcurrent: 8, clock: clock)
        try await limiter.acquire(units: 15, priority: .sync)
        await limiter.release()
        try await limiter.acquire(units: 15, priority: .interactive)
        await limiter.release()
        #expect(abs(clock.now.timeIntervalSince(start) - 2) < 0.01)
    }
}
