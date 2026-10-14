import Foundation
import OpenHumanGmail
import Synchronization

public final class SyncMetricsCollector: GmailMetricsSink {
    public struct Totals: Sendable, Equatable {
        public var units = 0
        public var requests = 0
        public var calls = 0
        public var failures = 0
        public init() {}
    }

    private let totals = Mutex(Totals())

    public init() {}

    public func record(_ metric: GmailCallMetric) {
        totals.withLock { t in
            t.units += metric.units
            t.requests += metric.attempts
            t.calls += 1
            if !(metric.status.map { (200..<300).contains($0) } ?? false) { t.failures += 1 }
        }
    }

    public var snapshot: Totals { totals.withLock { $0 } }
}

extension SyncMetricsCollector.Totals {
    static func - (a: Self, b: Self) -> Self {
        var d = Self()
        d.units = a.units - b.units
        d.requests = a.requests - b.requests
        d.calls = a.calls - b.calls
        d.failures = a.failures - b.failures
        return d
    }
}
