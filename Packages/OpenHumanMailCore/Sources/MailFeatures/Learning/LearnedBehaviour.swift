import Foundation
import OpenHumanCore

public enum TriageSignal: String, Sendable, Hashable, Codable, CaseIterable {
    case archivedUnread, archivedRead, repliedQuickly, repliedLater, starred, muted, movedToOther, movedToImportant

    public var isDismissal: Bool { self == .archivedUnread || self == .muted || self == .movedToOther }
    public var isEngagement: Bool {
        self == .repliedQuickly || self == .repliedLater || self == .starred || self == .movedToImportant
    }
}

public struct LearnedSubject: Sendable, Hashable, Codable, Comparable {
    public enum Kind: String, Sendable, Hashable, Codable { case sender, category }

    public var account: AccountID
    public var kind: Kind
    public var value: String

    public init(account: AccountID, kind: Kind, value: String) {
        self.account = account
        self.kind = kind
        self.value = kind == .sender ? value.lowercased() : value
    }

    public static func < (a: Self, b: Self) -> Bool {
        (a.account, a.kind.rawValue, a.value) < (b.account, b.kind.rawValue, b.value)
    }
}

public struct Tendency: Sendable, Hashable, Codable {
    public var weights: [TriageSignal: Double] = [:]
    public var counts: [TriageSignal: Int] = [:]
    public var asOf: Date
    public var lastSeen: Date

    public init(asOf: Date) {
        self.asOf = asOf
        self.lastSeen = asOf
    }

    public func decayed(to date: Date, halfLife: TimeInterval) -> Tendency {
        guard date > asOf, halfLife > 0 else { return self }
        let factor = pow(0.5, date.timeIntervalSince(asOf) / halfLife)
        var copy = self
        copy.weights = weights.mapValues { $0 * factor }
        copy.asOf = date
        return copy
    }

    public var totalWeight: Double { weights.values.reduce(0, +) }
    public var totalCount: Int { counts.values.reduce(0, +) }
    public func weight(_ matching: (TriageSignal) -> Bool) -> Double {
        weights.filter { matching($0.key) }.values.reduce(0, +)
    }
    public func count(_ matching: (TriageSignal) -> Bool) -> Int {
        counts.filter { matching($0.key) }.values.reduce(0, +)
    }
}

public struct LearnedSuggestionPolicy: Sendable, Hashable {
    public var senderMinimumWeight: Double = 4.5
    public var senderDismissalShare: Double = 0.8
    public var maximumEngagementWeight: Double = 0.5
    public var categoryMinimumWeight: Double = 9.5
    public var categoryDismissalShare: Double = 0.9
    public var dismissFor: TimeInterval = 30 * 86_400
    public var maximumSuggestions = 5

    public init() {}
}

public struct LearnedSuggestion: Identifiable, Sendable, Hashable {
    public var id: LearnedSubject { subject }
    public let subject: LearnedSubject
    public let dismissed: Int
    public let total: Int
    public let share: Double

    public var text: String {
        switch subject.kind {
        case .sender:
            return "You archived \(dismissed) of \(total) conversations from \(subject.value) without reading them. "
                + "Move this sender to Other?"
        case .category:
            return "You archived \(dismissed) of \(total) \(subject.value) conversations without reading them. "
                + "Move \(subject.value) mail to Other?"
        }
    }

    public var actionTitle: String { "Move to Other" }
}

public struct LearnedBehaviour: Sendable, Hashable, Codable {
    public static let halfLife: TimeInterval = 30 * 86_400
    public static let maximumSubjects = 2_000

    public private(set) var tendencies: [LearnedSubject: Tendency] = [:]
    public var notNow: [LearnedSubject: Date] = [:]
    public var accepted: Set<LearnedSubject> = []
    public var seededAccounts: Set<AccountID> = []
    public private(set) var autoLabelRejections: [LearnedSubject: Set<String>] = [:]
    public private(set) var wrongAutoLabelCounts: [LearnedSubject: Int] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case tendencies, notNow, accepted, seededAccounts, autoLabelRejections, wrongAutoLabelCounts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tendencies = try values.decodeIfPresent([LearnedSubject: Tendency].self, forKey: .tendencies) ?? [:]
        notNow = try values.decodeIfPresent([LearnedSubject: Date].self, forKey: .notNow) ?? [:]
        accepted = try values.decodeIfPresent(Set<LearnedSubject>.self, forKey: .accepted) ?? []
        seededAccounts = try values.decodeIfPresent(Set<AccountID>.self, forKey: .seededAccounts) ?? []
        autoLabelRejections = try values.decodeIfPresent([LearnedSubject: Set<String>].self,
                                                         forKey: .autoLabelRejections) ?? [:]
        wrongAutoLabelCounts = try values.decodeIfPresent([LearnedSubject: Int].self, forKey: .wrongAutoLabelCounts) ?? [:]
    }

    public mutating func recordWrongAutoLabel(_ category: String, account: AccountID, sender: String?) {
        wrongAutoLabelCounts[LearnedSubject(account: account, kind: .category, value: category), default: 0] += 1
        guard let sender, !sender.isEmpty else { return }
        autoLabelRejections[LearnedSubject(account: account, kind: .sender, value: sender), default: []].insert(category)
        if autoLabelRejections.count > Self.maximumSubjects, let first = autoLabelRejections.keys.min() {
            autoLabelRejections[first] = nil
        }
    }

    public func rejectedAutoLabels(account: AccountID, sender: String) -> Set<String> {
        autoLabelRejections[LearnedSubject(account: account, kind: .sender, value: sender)] ?? []
    }

    public var isEmpty: Bool { tendencies.isEmpty }
    public var observationCount: Int { tendencies.values.reduce(0) { $0 + $1.totalCount } }

    public mutating func record(_ signal: TriageSignal, for subject: LearnedSubject, at date: Date) {
        var tendency = (tendencies[subject] ?? Tendency(asOf: date)).decayed(to: date, halfLife: Self.halfLife)
        tendency.weights[signal, default: 0] += 1
        tendency.counts[signal, default: 0] += 1
        tendency.lastSeen = max(tendency.lastSeen, date)
        tendencies[subject] = tendency
        if tendencies.count > Self.maximumSubjects {
            let stalest = tendencies.min { $0.value.lastSeen < $1.value.lastSeen }?.key
            if let stalest { tendencies[stalest] = nil }
        }
    }

    public func tendency(for subject: LearnedSubject, at date: Date) -> Tendency? {
        tendencies[subject]?.decayed(to: date, halfLife: Self.halfLife)
    }

    public mutating func forget(account: AccountID) {
        tendencies = tendencies.filter { $0.key.account != account }
        notNow = notNow.filter { $0.key.account != account }
        accepted = accepted.filter { $0.account != account }
        seededAccounts.remove(account)
        autoLabelRejections = autoLabelRejections.filter { $0.key.account != account }
        wrongAutoLabelCounts = wrongAutoLabelCounts.filter { $0.key.account != account }
    }

    public func suggestions(at date: Date, policy: LearnedSuggestionPolicy = LearnedSuggestionPolicy(),
                            covered: Set<LearnedSubject> = []) -> [LearnedSuggestion] {
        var found: [LearnedSuggestion] = []
        for (subject, stored) in tendencies where !covered.contains(subject) && !accepted.contains(subject) {
            if let asked = notNow[subject], date.timeIntervalSince(asked) < policy.dismissFor { continue }
            let tendency = stored.decayed(to: date, halfLife: Self.halfLife)
            let total = tendency.totalWeight
            let minimum = subject.kind == .sender ? policy.senderMinimumWeight : policy.categoryMinimumWeight
            let wanted = subject.kind == .sender ? policy.senderDismissalShare : policy.categoryDismissalShare
            guard total >= minimum else { continue }
            let share = tendency.weight(\.isDismissal) / total
            guard share >= wanted, tendency.weight(\.isEngagement) <= policy.maximumEngagementWeight else { continue }
            found.append(LearnedSuggestion(subject: subject, dismissed: tendency.count(\.isDismissal),
                                           total: tendency.totalCount, share: share))
        }
        return Array(found.sorted { ($0.share, $0.total, $1.subject) > ($1.share, $1.total, $0.subject) }
            .prefix(policy.maximumSuggestions))
    }
}

public struct ClassifierAgreementReport: Sendable, Hashable {
    public struct Row: Identifiable, Sendable, Hashable {
        public var id: String { category }
        public let category: String
        public let agreeing: Int
        public let disagreeing: Int
        public let agreement: Double?

        public var text: String {
            guard let agreement else { return "Not enough actions yet" }
            return "\(Int((agreement * 100).rounded()))% agree (\(agreeing) of \(agreeing + disagreeing))"
        }
    }

    public static let minimumActions = 3
    public let rows: [Row]

    public static func expectation(for category: String) -> (agree: Set<TriageSignal>, disagree: Set<TriageSignal>)? {
        let engaged: Set<TriageSignal> = [.repliedQuickly, .repliedLater, .starred, .movedToImportant]
        let dismissed: Set<TriageSignal> = [.archivedUnread, .muted, .movedToOther]
        switch category.lowercased() {
        case "respond": return (engaged, dismissed)
        case "marketing", "news", "social", "pitch": return (dismissed, engaged)
        case "meeting", "invoice", "travel": return (engaged.union([.archivedRead]), [.archivedUnread, .muted])
        default: return nil
        }
    }

    public static func make(from behaviour: LearnedBehaviour, account: AccountID? = nil) -> ClassifierAgreementReport {
        var agree: [String: Int] = [:]
        var disagree: [String: Int] = [:]
        for (subject, tendency) in behaviour.tendencies where subject.kind == .category {
            if let account, subject.account != account { continue }
            guard let expected = expectation(for: subject.value) else { continue }
            agree[subject.value, default: 0] += tendency.count { expected.agree.contains($0) }
            disagree[subject.value, default: 0] += tendency.count { expected.disagree.contains($0) }
        }
        for (subject, count) in behaviour.wrongAutoLabelCounts where subject.kind == .category {
            if let account, subject.account != account { continue }
            disagree[subject.value, default: 0] += count
        }
        let rows = Set(agree.keys).union(disagree.keys).sorted().map { category -> Row in
            let a = agree[category] ?? 0, d = disagree[category] ?? 0
            return Row(category: category, agreeing: a, disagreeing: d,
                       agreement: a + d >= minimumActions ? Double(a) / Double(a + d) : nil)
        }
        return ClassifierAgreementReport(rows: rows)
    }
}
