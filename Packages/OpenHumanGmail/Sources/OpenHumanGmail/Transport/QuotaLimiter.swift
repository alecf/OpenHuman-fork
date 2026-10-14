import Foundation
import OpenHumanCore

public actor QuotaLimiter {
    public let unitsPerMinute: Int
    public let maxConcurrent: Int
    private let clock: any OHClock
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: Date
    private var pausedUntil: Date?
    private var slotsInUse = 0
    private var slotWaiters: [SlotWaiter] = []
    private var tokenWaiters: [TokenWaiter] = []
    private var nextID = 0
    private var timer: Task<Void, Never>?
    private var timerWake: Date?
    private var usage: [(at: Date, units: Int)] = []

    private struct SlotWaiter {
        var id: Int
        var priority: RequestPriority
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct TokenWaiter {
        var id: Int
        var priority: RequestPriority
        var units: Int
        var started: Date
        var continuation: CheckedContinuation<Void, any Error>
    }

    static let interactiveMaxWait: Duration = .seconds(2)
    static let epsilon = 0.001
    static let defaultPause: Duration = .seconds(30)
    static let backfillFloor = 0.5

    public init(unitsPerMinute: Int, maxConcurrent: Int, clock: any OHClock) {
        self.unitsPerMinute = max(unitsPerMinute, 60)
        self.maxConcurrent = max(maxConcurrent, 1)
        self.clock = clock
        capacity = Double(self.unitsPerMinute) / 4
        refillPerSecond = Double(self.unitsPerMinute) / 60
        tokens = capacity
        lastRefill = clock.now
    }

    public func acquire(units: Int, priority: RequestPriority) async throws {
        try Task.checkCancellation()
        try await acquireSlot(priority: priority)
        do {
            try await acquireTokens(units: units, priority: priority)
        } catch {
            release()
            throw error
        }
    }

    public func release() {
        if let index = Self.bestIndex(slotWaiters.map(\.priority)) {
            slotWaiters.remove(at: index).continuation.resume()
        } else {
            slotsInUse = max(0, slotsInUse - 1)
        }
    }

    public func noteRateLimited(retryAfter: Duration?) {
        refill()
        tokens = 0
        let until = clock.now.addingTimeInterval((retryAfter ?? Self.defaultPause).timeInterval)
        pausedUntil = max(pausedUntil ?? until, until)
        dispatch()
    }

    public func unitsUsed(since date: Date) -> Int {
        usage.reduce(0) { $1.at >= date ? $0 + $1.units : $0 }
    }

    public var connectionsInUse: Int { slotsInUse }

    var waiting: Int { slotWaiters.count + tokenWaiters.count }

    var chargedUnits: [Int] { usage.map(\.units) }

    private static func bestIndex(_ priorities: [RequestPriority]) -> Int? {
        var best: Int?
        for (index, priority) in priorities.enumerated() where best == nil || priority > priorities[best!] {
            best = index
        }
        return best
    }

    private func acquireSlot(priority: RequestPriority) async throws {
        if slotsInUse < maxConcurrent {
            slotsInUse += 1
            return
        }
        let id = nextWaiterID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    slotWaiters.append(SlotWaiter(id: id, priority: priority, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelSlotWaiter(id) }
        }
    }

    private func cancelSlotWaiter(_ id: Int) {
        guard let index = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
        slotWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func acquireTokens(units: Int, priority: RequestPriority) async throws {
        let id = nextWaiterID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                tokenWaiters.append(TokenWaiter(id: id, priority: priority, units: units, started: clock.now,
                                                continuation: continuation))
                dispatch()
            }
        } onCancel: {
            Task { await self.cancelTokenWaiter(id) }
        }
    }

    private func cancelTokenWaiter(_ id: Int) {
        guard let index = tokenWaiters.firstIndex(where: { $0.id == id }) else { return }
        tokenWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        dispatch()
    }

    private func nextWaiterID() -> Int {
        nextID += 1
        return nextID
    }

    private func dispatch() {
        refill()
        let now = clock.now
        let paused = pausedUntil.map { now < $0 } ?? false
        let order = tokenWaiters.indices.sorted {
            let (a, b) = (tokenWaiters[$0], tokenWaiters[$1])
            return a.priority != b.priority ? a.priority > b.priority : a.id < b.id
        }
        var served = Set<Int>()
        var next: Date?
        func want(_ date: Date) { next = next.map { min($0, date) } ?? date }
        for index in order {
            let waiter = tokenWaiters[index]
            let interactive = waiter.priority == .interactive
            let deadline = waiter.started.addingTimeInterval(Self.interactiveMaxWait.timeInterval)
            let need = min(Double(waiter.units), capacity)
            if interactive, now >= deadline {
                if tokens + Self.epsilon < need {
                    Log(.gmail).notice("quota: interactive request sent after \(Self.interactiveMaxWait) without tokens")
                }
            } else if !interactive, paused, let until = pausedUntil {
                want(until)
                continue
            } else {
                var ready = now
                let deficit = need - tokens
                if deficit > Self.epsilon { ready = now.addingTimeInterval(deficit / refillPerSecond) }
                if waiter.priority == .backfill {
                    let floorDeficit = capacity * Self.backfillFloor + Self.epsilon - tokens
                    if floorDeficit > 0 { ready = max(ready, now.addingTimeInterval(floorDeficit / refillPerSecond)) }
                }
                if ready > now {
                    var wake = max(ready, now.addingTimeInterval(0.001))
                    if interactive { wake = min(wake, deadline) }
                    want(wake)
                    if deficit > Self.epsilon { break }
                    continue
                }
            }
            tokens -= Double(waiter.units)
            record(waiter.units, at: now)
            served.insert(waiter.id)
        }
        if !served.isEmpty {
            let done = tokenWaiters.filter { served.contains($0.id) }
            tokenWaiters.removeAll { served.contains($0.id) }
            for waiter in done { waiter.continuation.resume() }
        }
        arm(next)
    }

    private func arm(_ wake: Date?) {
        guard let wake, !tokenWaiters.isEmpty else {
            timer?.cancel()
            timer = nil
            timerWake = nil
            return
        }
        if timer != nil, timerWake == wake { return }
        timer?.cancel()
        timerWake = wake
        timer = Task { [clock] in
            do { try await clock.sleep(until: wake) } catch { return }
            await self.timerFired(wake)
        }
    }

    private func timerFired(_ wake: Date) {
        guard timerWake == wake else { return }
        timer = nil
        timerWake = nil
        dispatch()
    }

    private func refill() {
        let now = clock.now
        let elapsed = now.timeIntervalSince(lastRefill)
        if elapsed > 0 {
            tokens = min(capacity, tokens + elapsed * refillPerSecond)
            lastRefill = now
        }
    }

    private func record(_ units: Int, at date: Date) {
        usage.append((date, units))
        if usage.count > 2_000 {
            let cutoff = date.addingTimeInterval(-3_600)
            usage.removeAll { $0.at < cutoff }
        }
    }
}
