import Foundation

public enum SearchEvalArm: String, Codable, Sendable, Hashable, CaseIterable {
    case lexical = "A.lexical"
    case vector = "B.vector"
    case hybrid = "C.hybrid"
    case planned = "D.hybrid+plan"
}

public struct SearchEvalReport: Codable, Sendable, Hashable {
    public struct ClassScore: Codable, Sendable, Hashable {
        public var queryClass: String
        public var queries: Int
        public var recallAt10: Double?
        public var ndcgAt10: Double?
        public var mrrAt10: Double?
        public var topOne: Double?
        public var zeroHitRate: Double
        public var resultsInTop10: Double
        public var semanticOnlyInTop10: Double
    }

    public struct Latency: Codable, Sendable, Hashable {
        public var p50Milliseconds: Double
        public var p95Milliseconds: Double
    }

    public struct ArmScore: Codable, Sendable, Hashable {
        public var arm: SearchEvalArm
        public var overall: ClassScore
        public var classes: [ClassScore]
        public var latency: Latency
    }

    public struct IndexStats: Codable, Sendable, Hashable {
        public var providerID: String
        public var modelVersion: String
        public var spaceID: String
        public var dimension: Int
        public var maxInputTokens: Int?
        public var storage: VectorStorage
        public var chunksPerMessage: Int
        public var messages: Int
        public var slots: Int
        public var bytes: Int
        public var buildSeconds: Double
        public var messagesPerMinute: Double
        public var queryEmbedding: Latency
    }

    public struct GridResult: Codable, Sendable, Hashable {
        public var best: FusionParameters
        public var tuningNDCGAt10: Double
        public var heldOut: ArmScore
    }

    public struct ThresholdRow: Codable, Sendable, Hashable {
        public var tau: Double
        public var negativeRelatedInTop10: Double
        public var paraphraseAndVagueRecallAt10: Double?
    }

    public struct RuleChecks: Codable, Sendable, Hashable {
        public var paraphraseVagueGainPoints: Double?
        public var exactRecallLossPoints: Double?
        public var exactTopOneLosses: Int?
        public var rule1QualityPasses: Bool?
        public var chosenTau: Double?
    }

    public struct PerQueryLine: Codable, Sendable, Hashable {
        public var line: Int
        public var queryClass: String
        public var arm: SearchEvalArm
        public var firstRelevantRank: Int?
        public var recallAt10: Double?
    }

    public var corpusEmails: Int
    public var queries: Int
    public var arms: [ArmScore]
    public var index: IndexStats?
    public var grid: GridResult?
    public var thresholds: [ThresholdRow]
    public var rules: RuleChecks
    public var perQuery: [PerQueryLine]?

    public var summary: String {
        var lines: [String] = []
        lines.append("corpus: \(corpusEmails) emails, \(queries) queries")
        if let index {
            lines.append("index: \(index.providerID) v=\(index.modelVersion) space=\(index.spaceID) dim=\(index.dimension) "
                + "storage=\(index.storage.rawValue) chunks=\(index.chunksPerMessage) messages=\(index.messages) "
                + "bytes=\(index.bytes) build=\(Self.number(index.buildSeconds))s "
                + "(\(Self.number(index.messagesPerMinute)) msg/min) query embed p50 \(Self.number(index.queryEmbedding.p50Milliseconds)) ms "
                + "p95 \(Self.number(index.queryEmbedding.p95Milliseconds)) ms")
        } else {
            lines.append("index: none (lexical arm only)")
        }
        lines.append("arm            class          n  recall@10  nDCG@10  MRR@10  top-1  zero-hit  results  related")
        for arm in arms {
            for score in [arm.overall] + arm.classes {
                lines.append(
                    arm.arm.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)
                        + score.queryClass.padding(toLength: 13, withPad: " ", startingAt: 0)
                        + String(format: " %3d", score.queries)
                        + "  " + Self.cell(score.recallAt10, width: 9) + "  " + Self.cell(score.ndcgAt10, width: 7)
                        + "  " + Self.cell(score.mrrAt10, width: 6) + "  " + Self.cell(score.topOne, width: 5)
                        + String(format: "  %8.2f  %7.2f  %7.2f", score.zeroHitRate, score.resultsInTop10,
                                 score.semanticOnlyInTop10))
            }
            lines.append("  latency p50 \(Self.number(arm.latency.p50Milliseconds)) ms, p95 \(Self.number(arm.latency.p95Milliseconds)) ms")
        }
        if let grid {
            lines.append("grid (rule 7): best k=\(Self.number(grid.best.k)) ws=\(Self.number(grid.best.semanticWeight)) "
                + "wr=\(Self.number(grid.best.recencyWeight)) tuning nDCG@10 \(Self.number(grid.tuningNDCGAt10)); held-out "
                + "recall@10 \(Self.cell(grid.heldOut.overall.recallAt10, width: 0)) nDCG@10 \(Self.cell(grid.heldOut.overall.ndcgAt10, width: 0))")
        }
        if !thresholds.isEmpty {
            lines.append("tau sweep (rule 4): " + thresholds.map {
                "τ=\(Self.number($0.tau)): related \(Self.number($0.negativeRelatedInTop10)), recall \(Self.cell($0.paraphraseAndVagueRecallAt10, width: 0))"
            }.joined(separator: "; "))
        }
        lines.append("rules: paraphrase+vague gain \(Self.cell(rules.paraphraseVagueGainPoints, width: 0)) pts, "
            + "exact recall loss \(Self.cell(rules.exactRecallLossPoints, width: 0)) pts, exact top-1 losses "
            + "\(rules.exactTopOneLosses.map(String.init) ?? "-"), rule 1 quality "
            + "\(rules.rule1QualityPasses.map { $0 ? "pass" : "fail" } ?? "-"), chosen τ \(rules.chosenTau.map(Self.number) ?? "-")")
        if let perQuery {
            for line in perQuery {
                lines.append("line \(line.line) \(line.queryClass) \(line.arm.rawValue): first relevant "
                    + "\(line.firstRelevantRank.map(String.init) ?? "-"), recall@10 \(Self.cell(line.recallAt10, width: 0))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func number(_ value: Double) -> String { String(format: "%.2f", value) }

    static func cell(_ value: Double?, width: Int) -> String {
        let text = value.map { String(format: "%.3f", $0) } ?? "-"
        return width > text.count ? String(repeating: " ", count: width - text.count) + text : text
    }
}
