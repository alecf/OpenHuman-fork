import Foundation
import OpenHumanCore

public enum SearchSortOrder: String, Codable, Sendable, CaseIterable, Hashable {
    case relevant, recent

    public var title: String {
        switch self {
        case .relevant: "Most relevant"
        case .recent: "Most recent"
        }
    }

    public var other: SearchSortOrder { self == .relevant ? .recent : .relevant }
}

public enum SearchRankingPreset: String, Codable, Sendable, CaseIterable, Hashable {
    case balanced, relevance, recentFirst, classic, custom

    public var title: String {
        switch self {
        case .balanced: "Balanced"
        case .relevance: "Relevance"
        case .recentFirst: "Recent first"
        case .classic: "Classic"
        case .custom: "Custom"
        }
    }

    public var detail: String {
        switch self {
        case .balanced: "Sender and subject matches first; then how well the words match; recency breaks ties."
        case .relevance: "The best text match first; recency barely counts."
        case .recentFirst: "Newer mail first among matches; sender and subject still help."
        case .classic: "The earlier ranking: 65% text match, 35% recency (90-day half-life). No sender, click or contact signals."
        case .custom: "Your own weights."
        }
    }
}

public struct SearchRankingWeights: Codable, Sendable, Hashable {
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

    public static let balanced = SearchRankingWeights(fields: 4, text: 0.45, meaning: 0.1, recency: 0.15, clicks: 0.15,
                                                      contacts: 0.1, halfLifeDays: 120, clickHalfLifeDays: 30)
    public static let relevance = SearchRankingWeights(fields: 4, text: 0.6, meaning: 0.15, recency: 0.05, clicks: 0.1,
                                                       contacts: 0.05, halfLifeDays: 365, clickHalfLifeDays: 30)
    public static let recentFirst = SearchRankingWeights(fields: 1, text: 0.25, meaning: 0.1, recency: 1, clicks: 0.1,
                                                         contacts: 0.05, halfLifeDays: 30, clickHalfLifeDays: 30)

    public var headerLevelsDominate: Bool {
        fields * 0.25 > text + meaning + recency + clicks + contacts
    }

    public enum Field: String, CaseIterable, Sendable, Hashable {
        case fields, text, meaning, recency, clicks, contacts, halfLifeDays, clickHalfLifeDays

        public var title: String {
            switch self {
            case .fields: "Sender and subject"
            case .text: "Words in the text"
            case .meaning: "Related by meaning"
            case .recency: "Recency"
            case .clicks: "Opened from search"
            case .contacts: "People you write to"
            case .halfLifeDays: "Recency half-life"
            case .clickHalfLifeDays: "Forget opens after"
            }
        }

        public var help: String {
            switch self {
            case .fields: "Points for the words in the sender's name or address, or together in the subject."
            case .text: "Points for how well the words match anywhere, more when they appear together."
            case .meaning: "Points for smart search's related results (when smart search is on)."
            case .recency: "Points for newer mail."
            case .clicks: "Points for conversations you opened from search on this Mac."
            case .contacts: "Points for people you send mail to."
            case .halfLifeDays: "Mail this many days old gets half the recency points."
            case .clickHalfLifeDays: "An open from search counts half after this many days."
            }
        }

        public var range: ClosedRange<Double> {
            switch self {
            case .fields: 0...5
            case .text, .meaning, .recency, .clicks, .contacts: 0...1
            case .halfLifeDays: 7...730
            case .clickHalfLifeDays: 7...365
            }
        }

        public var step: Double {
            switch self {
            case .fields: 0.25
            case .text, .meaning, .recency, .clicks, .contacts: 0.05
            case .halfLifeDays, .clickHalfLifeDays: 1
            }
        }

        public var isDays: Bool { self == .halfLifeDays || self == .clickHalfLifeDays }
    }

    public subscript(field: Field) -> Double {
        get {
            switch field {
            case .fields: fields
            case .text: text
            case .meaning: meaning
            case .recency: recency
            case .clicks: clicks
            case .contacts: contacts
            case .halfLifeDays: halfLifeDays
            case .clickHalfLifeDays: clickHalfLifeDays
            }
        }
        set {
            let value = min(max(newValue, field.range.lowerBound), field.range.upperBound)
            switch field {
            case .fields: fields = value
            case .text: text = value
            case .meaning: meaning = value
            case .recency: recency = value
            case .clicks: clicks = value
            case .contacts: contacts = value
            case .halfLifeDays: halfLifeDays = value
            case .clickHalfLifeDays: clickHalfLifeDays = value
            }
        }
    }
}

public struct SearchRankingSettings: Codable, Sendable, Hashable {
    public var sort: SearchSortOrder
    public var preset: SearchRankingPreset
    public var custom: SearchRankingWeights

    public init(sort: SearchSortOrder = .relevant, preset: SearchRankingPreset = .balanced,
                custom: SearchRankingWeights = .balanced) {
        self.sort = sort
        self.preset = preset
        self.custom = custom
    }

    public static let defaults = SearchRankingSettings()

    public var weights: SearchRankingWeights? {
        switch preset {
        case .balanced: .balanced
        case .relevance: .relevance
        case .recentFirst: .recentFirst
        case .custom: custom
        case .classic: nil
        }
    }

    enum CodingKeys: String, CodingKey { case sort, preset, custom }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sort = (try? c.decode(SearchSortOrder.self, forKey: .sort)) ?? .relevant
        preset = (try? c.decode(SearchRankingPreset.self, forKey: .preset)) ?? .balanced
        custom = (try? c.decode(SearchRankingWeights.self, forKey: .custom)) ?? .balanced
    }
}

public struct SearchSortOverride: Sendable, Hashable, Codable {
    public let query: String
    public let sort: SearchSortOrder

    public init(query: String, sort: SearchSortOrder) {
        self.query = query
        self.sort = sort
    }
}

public enum SearchResultsOrdering: String, Sendable, Hashable, Codable {
    case date, relevance
}

public struct SearchScoreExplanation: Sendable, Hashable {
    public struct Part: Sendable, Hashable {
        public let label: String
        public let value: Double
        public let weight: Double
        public var points: Double { value * weight }

        public init(label: String, value: Double, weight: Double) {
            self.label = label
            self.value = value
            self.weight = weight
        }
    }

    public let match: String?
    public let wordsTogether: Bool?
    public let parts: [Part]

    public init(match: String?, wordsTogether: Bool?, parts: [Part]) {
        self.match = match
        self.wordsTogether = wordsTogether
        self.parts = parts
    }

    public var total: Double { parts.reduce(0) { $0 + $1.points } }

    public var text: String {
        var lines = ["Search ranking: \(Self.number(total)) points"]
        if let match { lines.append("Match: \(match)") }
        if let wordsTogether { lines.append("Words together: \(wordsTogether ? "yes" : "no")") }
        for part in parts {
            lines.append("\(part.label): \(Self.number(part.value)) × \(Self.number(part.weight)) = \(Self.number(part.points))")
        }
        return lines.joined(separator: "\n")
    }

    static func number(_ value: Double) -> String { String(format: "%.3f", value) }
}

public protocol SearchRankingPort: AnyObject, Sendable {
    func settings() -> SearchRankingSettings
    func save(_ settings: SearchRankingSettings)
    func sortOverride() -> SearchSortOverride?
    func setSortOverride(_ override: SearchSortOverride?)
    func recordOpen(_ thread: ThreadKey) async
    func rememberedConversations() async -> Int
    func resetLearning() async
}
