import Foundation
import OpenHumanAI

public struct EvalReport: Codable, Sendable, Hashable {
    public struct CategoryScore: Codable, Sendable, Hashable {
        public var category: String
        public var support: Int
        public var predicted: Int
        public var truePositives: Int
        public var precision: Double
        public var recall: Double
        public var f1: Double
    }

    public struct Latency: Codable, Sendable, Hashable {
        public var p50Milliseconds: Double
        public var p95Milliseconds: Double
        public var meanMilliseconds: Double
    }

    public struct InjectionBehaviour: Codable, Sendable, Hashable {
        public var cases: Int
        public var errors: Int
        public var blankedReasons: Int
        public var categories: [String: Int]
    }

    public var providerID: String
    public var displayName: String
    public var modelVersion: String?
    public var dataLocation: String
    public var total: Int
    public var answered: Int
    public var failed: Int
    public var failureKinds: [String: Int]
    public var accuracy: Double
    public var injectionAccuracy: Double?
    public var priorityWithinOne: Double
    public var perCategory: [CategoryScore]
    public var confusion: [String: [String: Int]]
    public var latency: Latency
    public var injectionBehaviour: InjectionBehaviour

    public var summary: String {
        var lines: [String] = []
        lines.append("\(displayName) [\(providerID)] model=\(modelVersion ?? "-") location=\(dataLocation)")
        lines.append(
            "accuracy \(Self.percent(accuracy)) over \(total) emails (\(answered) answered, \(failed) failed); "
                + "priority within 1: \(Self.percent(priorityWithinOne))"
                + (injectionAccuracy.map { "; injection subset \(Self.percent($0))" } ?? ""))
        lines.append(
            String(
                format: "latency p50 %.0f ms, p95 %.0f ms, mean %.0f ms", latency.p50Milliseconds, latency.p95Milliseconds,
                latency.meanMilliseconds))
        lines.append("category        support predicted precision recall   f1")
        for score in perCategory {
            lines.append(
                score.category.padding(toLength: 15, withPad: " ", startingAt: 0)
                    + String(
                        format: " %7d %9d %9.2f %6.2f %5.2f", score.support, score.predicted, score.precision, score.recall,
                        score.f1))
        }
        if !failureKinds.isEmpty {
            lines.append("failures: " + failureKinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }
        lines.append(
            "injection corpus: \(injectionBehaviour.cases) cases, \(injectionBehaviour.errors) errors, "
                + "\(injectionBehaviour.blankedReasons) blanked reasons")
        return lines.joined(separator: "\n")
    }

    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}

public enum EvalStats {
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    public static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }
}
