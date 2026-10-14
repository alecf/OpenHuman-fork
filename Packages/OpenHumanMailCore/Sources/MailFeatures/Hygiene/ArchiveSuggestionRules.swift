import Foundation

public struct ArchiveSuggestionFacts: Sendable, Hashable {
    public var sender: String?
    public var isSpam = false
    public var isStarred = false
    public var isImportantByRule = false
    public var isSnoozed = false
    public var hasReminder = false
    public var isMuted = false
    public var authorWroteToSender = false
    public var userLabels: [String] = []
    public var categories: [String] = []

    public init(sender: String?) {
        self.sender = sender?.lowercased()
    }
}

public enum ArchiveSuggestionOverride: String, Sendable, Hashable, Codable {
    case always, never
}

public struct ArchiveSuggestionRules: Sendable, Hashable {
    public enum Decision: Sendable, Hashable {
        case include
        case exclude(Reason)
    }

    public enum Reason: String, Sendable, Hashable {
        case spam, neverRule, wroteToSender, ownDomain, userLabel, starred, important, snoozed, reminder, muted
        case needsAttention
    }

    public static let genericDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com", "ymail.com",
        "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "fastmail.com", "hey.com",
    ]
    public static let promotionLabelWords: Set<String> = ["promotions", "promotion", "marketing", "news", "newsletter",
                                                          "newsletters", "deals", "offers"]
    public static let protectedCategories: Set<String> = ["respond", "needsreply", "needs_reply", "waiting",
                                                          "awaitingreply", "awaiting_reply", "fyi"]

    public var overrides: [String: ArchiveSuggestionOverride]
    public var ownDomains: Set<String>

    public init(overrides: [String: ArchiveSuggestionOverride] = [:], ownDomains: Set<String> = []) {
        self.overrides = Dictionary(overrides.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.ownDomains = Set(ownDomains.map { $0.lowercased() })
    }

    public func decide(_ facts: ArchiveSuggestionFacts) -> Decision {
        if facts.isSpam { return .exclude(.spam) }
        switch override(for: facts.sender) {
        case .always?: return .include
        case .never?: return .exclude(.neverRule)
        case nil: break
        }
        if facts.authorWroteToSender { return .exclude(.wroteToSender) }
        if let domain = Self.domain(of: facts.sender), ownDomains.contains(domain), !Self.genericDomains.contains(domain) {
            return .exclude(.ownDomain)
        }
        if facts.userLabels.contains(where: { !Self.isPromotionLabel($0) }) { return .exclude(.userLabel) }
        if facts.isStarred { return .exclude(.starred) }
        if facts.isImportantByRule { return .exclude(.important) }
        if facts.isSnoozed { return .exclude(.snoozed) }
        if facts.hasReminder { return .exclude(.reminder) }
        if facts.isMuted { return .exclude(.muted) }
        if facts.categories.contains(where: { Self.protectedCategories.contains(Self.normalized($0)) }) {
            return .exclude(.needsAttention)
        }
        return .include
    }

    func override(for sender: String?) -> ArchiveSuggestionOverride? {
        guard let sender else { return nil }
        if let own = overrides[sender] { return own }
        return Self.domain(of: sender).flatMap { overrides["@" + $0] }
    }

    static func domain(of address: String?) -> String? {
        guard let address, let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...].lowercased()
        return domain.isEmpty ? nil : domain
    }

    static func isPromotionLabel(_ name: String) -> Bool {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        return promotionLabelWords.contains(last.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func normalized(_ category: String) -> String {
        let last = category.split(separator: "/").last.map(String.init) ?? category
        return last.lowercased().filter { $0.isLetter || $0 == "_" }
    }
}
