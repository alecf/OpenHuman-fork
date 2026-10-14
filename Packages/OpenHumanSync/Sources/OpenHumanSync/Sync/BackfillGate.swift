import Foundation
import OpenHumanCore
import Synchronization

public enum BackfillHold: String, Sendable, Hashable {
    case offline
    case interactive
    case queueDrain
    case lowPower
}

public final class BackfillGate: Sendable {
    public static let interactiveGrace: Duration = .seconds(3)
    public static let recheck: Duration = .seconds(5)

    private struct State {
        var interactive = 0
        var lastInteractiveEnd: Date?
        var draining = 0
    }
    private let state = Mutex(State())
    private let isReachable: @Sendable () -> Bool
    private let isConstrained: @Sendable () -> Bool

    public init(isReachable: @escaping @Sendable () -> Bool = { true },
                isConstrained: @escaping @Sendable () -> Bool = BackfillGate.systemIsConstrained) {
        self.isReachable = isReachable
        self.isConstrained = isConstrained
    }

    public static let systemIsConstrained: @Sendable () -> Bool = {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }

    public func beginInteractive() { state.withLock { $0.interactive += 1 } }

    public func endInteractive(now: Date) {
        state.withLock {
            $0.interactive = max(0, $0.interactive - 1)
            $0.lastInteractiveEnd = now
        }
    }

    public func beginDraining() { state.withLock { $0.draining += 1 } }
    public func endDraining() { state.withLock { $0.draining = max(0, $0.draining - 1) } }

    public func hold(now: Date) -> BackfillHold? {
        if !isReachable() { return .offline }
        let (interactive, lastEnd, draining) = state.withLock { ($0.interactive, $0.lastInteractiveEnd, $0.draining) }
        if interactive > 0 { return .interactive }
        if let lastEnd, now.timeIntervalSince(lastEnd) < Self.interactiveGrace.timeInterval { return .interactive }
        if draining > 0 { return .queueDrain }
        if isConstrained() { return .lowPower }
        return nil
    }
}
