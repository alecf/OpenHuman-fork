import Foundation
import OpenHumanCore

public enum SearchIncompleteReason: Hashable, Sendable {
    case olderMailNeedsGmailFallback(accounts: [AccountID], searchedBack: Date?)
    case bodiesPartiallyIndexed(messages: Int)
    case candidateLimitReached(limit: Int)
}

public struct SearchCompleteness: Hashable, Sendable {
    public var reasons: [SearchIncompleteReason]
    public var gmailQuery: String

    public var isComplete: Bool { reasons.isEmpty }
    public var needsGmailFallback: Bool {
        reasons.contains { if case .olderMailNeedsGmailFallback = $0 { return true } else { return false } }
    }

    public init(
        reasons: [SearchIncompleteReason] = [],
        gmailQuery: String = ""
    ) {
        self.reasons = reasons
        self.gmailQuery = gmailQuery
    }
}

public struct SearchCandidate: Hashable, Sendable {
    public var threadID: ThreadRowID
    public var bestMessageID: MessageRowID
    public var matchedMessageIDs: [MessageRowID]
    public var bestAt: Date
    public var newestAt: Date
    public var bm25: Double?
    public var externalScore: Double?
    public var headerMatch: SearchHeaderMatch?
    public var sentToCorrespondent: Int?
    public var wordsTogether: Bool?

    public init(
        threadID: ThreadRowID,
        bestMessageID: MessageRowID,
        matchedMessageIDs: [MessageRowID],
        bestAt: Date,
        newestAt: Date,
        bm25: Double? = nil,
        externalScore: Double? = nil,
        headerMatch: SearchHeaderMatch? = nil,
        sentToCorrespondent: Int? = nil,
        wordsTogether: Bool? = nil
    ) {
        self.threadID = threadID
        self.bestMessageID = bestMessageID
        self.matchedMessageIDs = matchedMessageIDs
        self.bestAt = bestAt
        self.newestAt = newestAt
        self.bm25 = bm25
        self.externalScore = externalScore
        self.headerMatch = headerMatch
        self.sentToCorrespondent = sentToCorrespondent
        self.wordsTogether = wordsTogether
    }
}

public struct SearchRankingInputs: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let fields = SearchRankingInputs(rawValue: 1 << 0)
    public static let contacts = SearchRankingInputs(rawValue: 1 << 1)
    public static let phrase = SearchRankingInputs(rawValue: 1 << 2)
}

public protocol SearchRanking: Sendable {
    func scores(for candidates: [SearchCandidate], query: SearchQuery, now: Date) -> [Double]
    var inputs: SearchRankingInputs { get }
    var ordersByDate: Bool { get }
    func rankedScores(for candidates: [SearchCandidate], query: SearchQuery, now: Date)
        -> (scores: [Double], breakdowns: [SearchScoreBreakdown]?)
}

extension SearchRanking {
    public var inputs: SearchRankingInputs { [] }
    public var ordersByDate: Bool { false }
    public func rankedScores(for candidates: [SearchCandidate], query: SearchQuery, now: Date)
        -> (scores: [Double], breakdowns: [SearchScoreBreakdown]?) {
        (scores(for: candidates, query: query, now: now), nil)
    }
}

public struct BM25RecencyRanking: SearchRanking {
    public var relevanceWeight: Double
    public var recencyWeight: Double
    public var halfLifeDays: Double

    public init(relevanceWeight: Double = 0.65, recencyWeight: Double = 0.35, halfLifeDays: Double = 90) {
        self.relevanceWeight = relevanceWeight
        self.recencyWeight = recencyWeight
        self.halfLifeDays = max(halfLifeDays, 0.001)
    }

    public func scores(for candidates: [SearchCandidate], query: SearchQuery, now: Date) -> [Double] {
        let relevances = candidates.map { max(0, -($0.bm25 ?? 0)) }
        let best = relevances.max() ?? 0
        return zip(candidates, relevances).map { candidate, relevance in
            let ageDays = max(0, now.timeIntervalSince(candidate.newestAt)) / 86_400
            let recency = pow(0.5, ageDays / halfLifeDays)
            let normalized = best > 0 ? relevance / best : 1
            return relevanceWeight * normalized + recencyWeight * recency
        }
    }
}

public struct HybridRRFRanking: SearchRanking {
    public var k: Double
    public var lexicalWeight: Double
    public var externalWeight: Double
    public var recencyWeight: Double

    public init(k: Double = 60, lexicalWeight: Double = 1.0, externalWeight: Double = 1.0, recencyWeight: Double = 0.25) {
        self.k = max(k, 0)
        self.lexicalWeight = lexicalWeight
        self.externalWeight = externalWeight
        self.recencyWeight = recencyWeight
    }

    public func scores(for candidates: [SearchCandidate], query: SearchQuery, now: Date) -> [Double] {
        let lexical = Self.ranks(candidates, by: { $0.bm25.map { -$0 } })
        let external = Self.ranks(candidates, by: { $0.externalScore })
        let recency = Self.ranks(candidates, by: { $0.newestAt.timeIntervalSince1970 })
        return candidates.indices.map { index in
            var score = 0.0
            if let rank = lexical[index] { score += lexicalWeight / (k + Double(rank)) }
            if let rank = external[index] { score += externalWeight / (k + Double(rank)) }
            if let rank = recency[index] { score += recencyWeight / (k + Double(rank)) }
            return score
        }
    }

    static func ranks(_ candidates: [SearchCandidate], by value: (SearchCandidate) -> Double?) -> [Int?] {
        let ranked = candidates.indices.compactMap { index -> (index: Int, value: Double)? in
            guard let v = value(candidates[index]), v.isFinite else { return nil }
            return (index, v)
        }.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            let ca = candidates[a.index], cb = candidates[b.index]
            if ca.newestAt != cb.newestAt { return ca.newestAt > cb.newestAt }
            return ca.threadID.rawValue > cb.threadID.rawValue
        }
        var ranks = [Int?](repeating: nil, count: candidates.count)
        for (position, entry) in ranked.enumerated() { ranks[entry.index] = position + 1 }
        return ranks
    }
}

public struct SearchSuggestion: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case contact, recentSearch, savedSearch, label, operatorCompletion, naturalLanguage }
    public var kind: Kind
    public var title: String
    public var query: SearchQuery

    public init(
        kind: Kind,
        title: String,
        query: SearchQuery
    ) {
        self.kind = kind
        self.title = title
        self.query = query
    }
}

public protocol SearchSuggesting: Sendable {
    func suggestions(forPartialQuery text: String, limit: Int) async throws -> [SearchSuggestion]
}

public protocol SearchQueryRewriting: Sendable {
    func rewrite(_ naturalLanguage: String) async throws -> SearchQuery?
}
