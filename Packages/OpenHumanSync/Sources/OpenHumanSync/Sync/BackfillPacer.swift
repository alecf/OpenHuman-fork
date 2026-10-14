import Foundation
import OpenHumanCore
import OpenHumanGmail

struct BackfillPacer: Sendable {
    let unitsPerMinute: Int
    var capacity: Double { Double(unitsPerMinute) / 4 }
    var refillPerSecond: Double { Double(unitsPerMinute) / 60 }

    private(set) var tokens: Double
    private var stamp: Date?
    private(set) var units = 0
    private(set) var calls = 0

    init(unitsPerMinute: Int) {
        self.unitsPerMinute = max(unitsPerMinute, 60)
        tokens = Double(max(unitsPerMinute, 60)) / 4
    }

    mutating func charge(_ cost: Int, calls n: Int = 1, now: Date) -> Duration {
        if let stamp {
            tokens = min(capacity, tokens + max(0, now.timeIntervalSince(stamp)) * refillPerSecond)
        }
        stamp = now
        tokens -= Double(cost)
        units += cost
        calls += n
        guard tokens < 0 else { return .zero }
        return .milliseconds(Int64((-tokens / refillPerSecond * 1000).rounded(.up)))
    }

    static func cost(_ method: GmailMethod, count: Int = 1) -> Int { QuotaCost.units(method) * count }
}
