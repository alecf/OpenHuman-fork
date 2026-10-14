import Foundation

public enum RetrievalMetrics {
    public static func recall(_ ranked: [String], grades: [String: Int], k: Int = 10) -> Double? {
        let relevant = grades.filter { $0.value > 0 }
        guard !relevant.isEmpty else { return nil }
        let found = Set(ranked.prefix(k)).filter { (grades[$0] ?? 0) > 0 }.count
        return Double(found) / Double(relevant.count)
    }

    public static func ndcg(_ ranked: [String], grades: [String: Int], k: Int = 10) -> Double? {
        let ideal = grades.values.filter { $0 > 0 }.sorted(by: >)
        guard !ideal.isEmpty else { return nil }
        func gain(_ grade: Int) -> Double { pow(2, Double(grade)) - 1 }
        var dcg = 0.0
        var seen = Set<String>()
        for (index, thread) in ranked.prefix(k).enumerated() where seen.insert(thread).inserted {
            dcg += gain(grades[thread] ?? 0) / log2(Double(index + 2))
        }
        var idcg = 0.0
        for (index, grade) in ideal.prefix(k).enumerated() { idcg += gain(grade) / log2(Double(index + 2)) }
        return idcg > 0 ? dcg / idcg : nil
    }

    public static func reciprocalRank(_ ranked: [String], grades: [String: Int], k: Int = 10) -> Double? {
        guard grades.values.contains(where: { $0 > 0 }) else { return nil }
        for (index, thread) in ranked.prefix(k).enumerated() where (grades[thread] ?? 0) > 0 {
            return 1 / Double(index + 1)
        }
        return 0
    }

    public static func topOne(_ ranked: [String], grades: [String: Int]) -> Bool? {
        guard grades.values.contains(2) else { return nil }
        guard let first = ranked.first else { return false }
        return grades[first] == 2
    }

    public static func precision(_ ranked: [String], relevant: Set<String>, k: Int = 20) -> Double {
        guard k > 0 else { return 0 }
        return Double(ranked.prefix(k).filter(relevant.contains).count) / Double(k)
    }

    public static func mean(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }
        return present.isEmpty ? nil : present.reduce(0, +) / Double(present.count)
    }

    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}
