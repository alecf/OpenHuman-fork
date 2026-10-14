import Foundation
import Synchronization

public protocol OHClock: Sendable {
    var now: Date { get }
    func sleep(until deadline: Date) async throws
    func sleep(for duration: Duration) async throws
}

extension OHClock {
    public func sleep(for duration: Duration) async throws {
        try await sleep(until: now.addingTimeInterval(duration.timeInterval))
    }
}

extension Duration {
    public var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}

public struct SystemClock: OHClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        if interval > 0 { try await Task.sleep(for: .seconds(interval)) } else { try Task.checkCancellation() }
    }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public final class TestClock: OHClock {
    private struct Sleeper {
        let id: UInt64
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct State {
        var now: Date
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
    }
    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        state = Mutex(State(now: now))
    }

    public var now: Date { state.withLock { $0.now } }

    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public var nextDeadline: Date? { state.withLock { $0.sleepers.map(\.deadline).min() } }

    public func sleep(until deadline: Date) async throws {
        try Task.checkCancellation()
        let id: UInt64 = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let resumeNow: Bool = state.withLock { s in
                    if deadline <= s.now { return true }
                    if Task.isCancelled { return true }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: cont))
                    return false
                }
                if resumeNow {
                    if Task.isCancelled { cont.resume(throwing: CancellationError()) } else { cont.resume() }
                }
            }
        } onCancel: {
            let cont: CheckedContinuation<Void, Error>? = state.withLock { s in
                guard let i = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: i).continuation
            }
            cont?.resume(throwing: CancellationError())
        }
    }

    public func advance(by duration: Duration) {
        advance(to: now.addingTimeInterval(duration.timeInterval))
    }

    public func advance(to date: Date) {
        let due: [Sleeper] = state.withLock { s in
            if date > s.now { s.now = date }
            let ready = s.sleepers.filter { $0.deadline <= s.now }
            s.sleepers.removeAll { $0.deadline <= s.now }
            return ready.sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
