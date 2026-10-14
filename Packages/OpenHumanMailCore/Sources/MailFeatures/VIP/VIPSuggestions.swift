import Foundation
import MailModel
import OpenHumanCore

public struct VIPSuggestion: Identifiable, Hashable, Sendable {
    public let account: AccountID
    public let email: String
    public let name: String?
    public let recentReplies: Int
    public let score: Double

    public init(account: AccountID, email: String, name: String?, recentReplies: Int, score: Double) {
        self.account = account
        self.email = email
        self.name = name
        self.recentReplies = recentReplies
        self.score = score
    }

    public var id: String { "\(account.rawValue)|\(email)" }

    public var displayName: String {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return email }
        return name
    }

    public var question: String { "Mark \(displayName) as VIP?" }

    public var reason: String {
        let days = Int((VIPSuggestionPolicy.window / 86_400).rounded())
        return "You replied \(recentReplies) time\(recentReplies == 1 ? "" : "s") in the last \(days) days."
    }
}

public enum VIPSuggestionPolicy {
    public static let window: TimeInterval = 30 * 86_400
    public static let minimumReplies = 3
    public static let halfLife: TimeInterval = 14 * 86_400
    public static let lookback: TimeInterval = 90 * 86_400
    public static let maximumSuggestions = 10

    static let automatedPrefixes = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply",
                                    "mailer-daemon", "postmaster", "bounce", "notifications", "notification"]

    public static func weightedFrequency(_ dates: [Date], now: Date, halfLife: TimeInterval = halfLife) -> Double {
        guard halfLife > 0 else { return Double(dates.count) }
        return dates.reduce(0) { sum, date in sum + pow(0.5, max(0, now.timeIntervalSince(date)) / halfLife) }
    }

    public static func recentCount(_ dates: [Date], now: Date, window: TimeInterval = window) -> Int {
        dates.reduce(0) { $0 + (now.timeIntervalSince($1) <= window ? 1 : 0) }
    }

    public static func isAutomated(_ email: String) -> Bool {
        let local = email.lowercased().split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        return automatedPrefixes.contains { local.hasPrefix($0) }
    }

    static func domain(of email: String) -> String {
        email.lowercased().split(separator: "@").last.map(String.init) ?? ""
    }

    public static func exclusions(rules: [ImportanceRuleInfo], marked: Set<String>, declined: Set<String>)
        -> (senders: Set<String>, domains: Set<String>) {
        var senders = marked.union(declined)
        var domains: Set<String> = []
        for rule in rules {
            switch rule.match {
            case .sender: senders.insert(rule.value.lowercased())
            case .domain: domains.insert(rule.value.lowercased())
            default: break
            }
        }
        return (senders, domains)
    }

    public static func suggestions(_ counters: [ContactReplyCounter], account: AccountID, now: Date,
                                   minimumReplies: Int = minimumReplies, excludedSenders: Set<String>,
                                   excludedDomains: Set<String>) -> [VIPSuggestion] {
        let found: [VIPSuggestion] = counters.compactMap { counter in
            let email = counter.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !email.isEmpty, !excludedSenders.contains(email), !isAutomated(email),
                  !excludedDomains.contains(domain(of: email)) else { return nil }
            let recent = recentCount(counter.repliedAt, now: now)
            guard recent >= max(1, minimumReplies) else { return nil }
            return VIPSuggestion(account: account, email: email, name: counter.name, recentReplies: recent,
                                 score: weightedFrequency(counter.repliedAt, now: now))
        }
        let sorted = found.sorted { $0.score != $1.score ? $0.score > $1.score : $0.email < $1.email }
        return Array(sorted.prefix(maximumSuggestions))
    }
}
