import Foundation

public struct PerfStats: Sendable, Equatable {
    public let count: Int
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let max: Double
    public let mean: Double

    public init(_ samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = Int((Double(sorted.count - 1) * p).rounded(.up))
            return sorted[Swift.min(index, sorted.count - 1)]
        }
        p50 = percentile(0.50)
        p95 = percentile(0.95)
        p99 = percentile(0.99)
        max = sorted.last ?? 0
        mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
    }

}

public struct PerfBudget: Sendable, Equatable {
    public var p95: Double?
    public var max: Double?

    public init(p95: Double? = nil, max: Double? = nil) {
        self.p95 = p95
        self.max = max
    }

    public static let frame = 1000.0 / 120.0
}

public struct PerfResult: Sendable {
    public let name: String
    public let stats: PerfStats
    public let budget: PerfBudget?
    public let overOneFrame: Int
    public let overTwoFrames: Int
    public let notes: [String]

    public init(name: String, samples: [Double], budget: PerfBudget?, notes: [String] = []) {
        self.name = name
        stats = PerfStats(samples)
        self.budget = budget
        overOneFrame = samples.filter { $0 > PerfBudget.frame }.count
        overTwoFrames = samples.filter { $0 > 2 * PerfBudget.frame }.count
        self.notes = notes
    }

    public var failures: [String] {
        guard let budget else { return [] }
        var result: [String] = []
        if let p95 = budget.p95, stats.p95 > p95 { result.append("\(name): p95 \(Self.ms(stats.p95)) > \(Self.ms(p95))") }
        if let max = budget.max, stats.max > max { result.append("\(name): max \(Self.ms(stats.max)) > \(Self.ms(max))") }
        return result
    }

    static func ms(_ value: Double) -> String { String(format: "%.3f ms", value) }
}

public struct PerfReport: Sendable {
    public var header: [String] = []
    public var results: [PerfResult] = []

    public init() {}

    public var failures: [String] { results.flatMap(\.failures) }

    public func result(_ name: String) -> PerfResult? { results.first { $0.name == name } }

    public var text: String {
        var lines = header
        lines.append("")
        lines.append("operation".padding(toLength: 52, withPad: " ", startingAt: 0)
                     + "     n     p50      p95      p99      max  >8.3ms >16.7ms  budget")
        for r in results {
            let budget = r.budget.map { b in
                [b.p95.map { "p95≤" + String(format: "%.1f", $0) }, b.max.map { "max≤" + String(format: "%.1f", $0) }]
                    .compactMap { $0 }.joined(separator: " ")
            } ?? "-"
            let ok = r.failures.isEmpty ? "" : "  OVER"
            lines.append(r.name.padding(toLength: 52, withPad: " ", startingAt: 0)
                         + String(format: "%6d %7.3f %8.3f %8.3f %8.3f %7d %7d  ", r.stats.count, r.stats.p50, r.stats.p95,
                                  r.stats.p99, r.stats.max, r.overOneFrame, r.overTwoFrames)
                         + budget + ok)
            for note in r.notes { lines.append("    " + note) }
        }
        let failures = self.failures
        lines.append("")
        lines.append(failures.isEmpty ? "All budgets met." : "Over budget:\n  " + failures.joined(separator: "\n  "))
        return lines.joined(separator: "\n")
    }
}
