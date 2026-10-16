import Foundation
import OpenHumanCore

public struct SearchScoreBreakdown: Hashable, Sendable {
    public enum Signal: String, Hashable, Sendable, CaseIterable {
        case fields, text, meaning, recency, clicks, contacts

        public var label: String {
            switch self {
            case .fields: "Sender and subject"
            case .text: "Words in the text"
            case .meaning: "Related by meaning"
            case .recency: "Recency"
            case .clicks: "Opened from search"
            case .contacts: "People you write to"
            }
        }
    }

    public struct Part: Hashable, Sendable {
        public let signal: Signal
        public let value: Double
        public let weight: Double
        public var points: Double { value * weight }

        public init(signal: Signal, value: Double, weight: Double) {
            self.signal = signal
            self.value = value
            self.weight = weight
        }
    }

    public let match: SearchHeaderMatch?
    public let wordsTogether: Bool?
    public let parts: [Part]

    public var total: Double { parts.reduce(0) { $0 + $1.points } }

    public init(match: SearchHeaderMatch?, wordsTogether: Bool?, parts: [Part]) {
        self.match = match
        self.wordsTogether = wordsTogether
        self.parts = parts
    }

    public func part(_ signal: Signal) -> Part? { parts.first { $0.signal == signal } }
}

public struct SearchClickHistory: Hashable, Sendable, Codable {
    public var score: Double
    public var at: Date

    public init(score: Double, at: Date) {
        self.score = score
        self.at = at
    }

    public func decayed(at now: Date, halfLifeDays: Double) -> Double {
        let days = max(0, now.timeIntervalSince(at)) / 86_400
        return score * pow(0.5, days / max(halfLifeDays, 0.001))
    }

    public func adding(_ opens: Double = 1, at now: Date, halfLifeDays: Double) -> SearchClickHistory {
        SearchClickHistory(score: decayed(at: now, halfLifeDays: halfLifeDays) + opens, at: max(now, at))
    }
}

public struct BlendedSearchRanking: SearchRanking {
    public struct Weights: Hashable, Sendable, Codable {
        public var fields: Double
        public var text: Double
        public var meaning: Double
        public var recency: Double
        public var clicks: Double
        public var contacts: Double
        public var halfLifeDays: Double
        public var clickHalfLifeDays: Double

        public init(fields: Double, text: Double, meaning: Double, recency: Double, clicks: Double, contacts: Double,
                    halfLifeDays: Double, clickHalfLifeDays: Double) {
            self.fields = fields
            self.text = text
            self.meaning = meaning
            self.recency = recency
            self.clicks = clicks
            self.contacts = contacts
            self.halfLifeDays = halfLifeDays
            self.clickHalfLifeDays = clickHalfLifeDays
        }

        public static let balanced = Weights(fields: 4, text: 0.45, meaning: 0.1, recency: 0.15, clicks: 0.15, contacts: 0.1,
                                             halfLifeDays: 120, clickHalfLifeDays: 30)

        public var headerLevelsDominate: Bool {
            fields * 0.25 > text + meaning + recency + clicks + contacts
        }
    }

    public static let meaningRankConstant = 60.0
    public static let contactHalfPoint = 5.0
    public static let togetherShare = 0.25

    public var weights: Weights
    public var clicks: [ThreadRowID: SearchClickHistory]

    public init(weights: Weights = .balanced, clicks: [ThreadRowID: SearchClickHistory] = [:]) {
        self.weights = weights
        self.clicks = clicks
    }

    public var inputs: SearchRankingInputs {
        var inputs: SearchRankingInputs = []
        if weights.fields > 0 { inputs.insert(.fields) }
        if weights.contacts > 0 { inputs.insert(.contacts) }
        if weights.text > 0 { inputs.insert(.phrase) }
        return inputs
    }

    public func scores(for candidates: [SearchCandidate], query: SearchQuery, now: Date) -> [Double] {
        breakdowns(for: candidates, now: now).map(\.total)
    }

    public func rankedScores(for candidates: [SearchCandidate], query: SearchQuery, now: Date)
        -> (scores: [Double], breakdowns: [SearchScoreBreakdown]?) {
        let parts = breakdowns(for: candidates, now: now)
        return (parts.map(\.total), parts)
    }

    public func breakdowns(for candidates: [SearchCandidate], now: Date) -> [SearchScoreBreakdown] {
        let relevances = candidates.map { candidate in candidate.bm25.map { max(0, -$0) } }
        let best = relevances.compactMap { $0 }.max() ?? 0
        let meaningRanks = HybridRRFRanking.ranks(candidates, by: { $0.externalScore })
        let w = weights
        return candidates.indices.map { index in
            let candidate = candidates[index]
            var text = 0.0
            if let relevance = relevances[index], relevance.isFinite {
                let normalized = best > 0 ? relevance / best : 1
                if let together = candidate.wordsTogether {
                    text = (1 - Self.togetherShare) * normalized + Self.togetherShare * (together ? 1 : 0)
                } else {
                    text = normalized
                }
            }
            let meaning = meaningRanks[index].map { Self.meaningRankConstant / (Self.meaningRankConstant + Double($0 - 1)) } ?? 0
            let ageDays = max(0, now.timeIntervalSince(candidate.newestAt)) / 86_400
            let recency = pow(0.5, ageDays / max(w.halfLifeDays, 0.001))
            let opens = clicks[candidate.threadID]?.decayed(at: now, halfLifeDays: w.clickHalfLifeDays) ?? 0
            let sent = Double(max(candidate.sentToCorrespondent ?? 0, 0))
            let parts: [SearchScoreBreakdown.Part] = [
                .init(signal: .fields, value: candidate.headerMatch?.value ?? 0, weight: w.fields),
                .init(signal: .text, value: text, weight: w.text),
                .init(signal: .meaning, value: meaning, weight: w.meaning),
                .init(signal: .recency, value: recency, weight: w.recency),
                .init(signal: .clicks, value: opens / (opens + 1), weight: w.clicks),
                .init(signal: .contacts, value: sent / (sent + Self.contactHalfPoint), weight: w.contacts),
            ]
            return SearchScoreBreakdown(match: candidate.headerMatch, wordsTogether: candidate.wordsTogether, parts: parts)
        }
    }
}

public struct NewestFirstSearchRanking: SearchRanking {
    public init() {}

    public var ordersByDate: Bool { true }

    public func scores(for candidates: [SearchCandidate], query: SearchQuery, now: Date) -> [Double] {
        candidates.map { $0.newestAt.timeIntervalSince1970 }
    }
}
