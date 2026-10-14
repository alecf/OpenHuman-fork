import Foundation
import MailModel
import OpenHumanAI

public enum NeedsReplySkip: String, Equatable, Sendable, CaseIterable {
    case youWroteLast
    case noReplySender
    case newsletter
    case automated
    case excluded
}

public enum NeedsReply {
    public struct Facts: Hashable, Sendable {
        public var lastIsFromMe: Bool
        public var sender: String?
        public var exclusion: QuickReplyExclusion.Facts
        public var triage: TriageCategory?

        public init(lastIsFromMe: Bool, sender: String? = nil, exclusion: QuickReplyExclusion.Facts = .init(),
                    triage: TriageCategory? = nil) {
            self.lastIsFromMe = lastIsFromMe
            self.sender = sender
            self.exclusion = exclusion
            self.triage = triage
        }
    }

    static let automatedCategories: Set<String> = ["CATEGORY_UPDATES", "CATEGORY_FORUMS"]

    static let noReplyLocalParts: Set<String> = [
        "noreply", "donotreply", "noreplies", "notifications", "notification", "notify", "mailerdaemon",
        "postmaster", "bounce", "bounces", "alerts", "alert", "automated", "autoreply", "autoresponder",
    ]

    public static func skipReason(_ facts: Facts) -> NeedsReplySkip? {
        if facts.lastIsFromMe { return .youWroteLast }
        if let exclusion = QuickReplyExclusion.reason(facts.exclusion) {
            return exclusion == .bulkSender ? .newsletter : .excluded
        }
        if let sender = facts.sender, isNoReply(sender) { return .noReplySender }
        if facts.exclusion.categories?.contains(where: { automatedCategories.contains($0.rawValue.uppercased()) }) == true {
            return .automated
        }
        switch facts.triage {
        case .newsletter?: return .newsletter
        case .notification?, .receipt?: return .automated
        case .needsReply?, .fyi?, .calendar?, .personal?, .other?, nil: return nil
        }
    }

    public static func isNoReply(_ address: String) -> Bool {
        let local = address.lowercased().split(separator: "@").first.map(String.init) ?? ""
        let folded = local.filter { $0 != "." && $0 != "-" && $0 != "_" }
        guard !folded.isEmpty else { return false }
        if noReplyLocalParts.contains(folded) { return true }
        return folded.hasPrefix("noreply") || folded.hasPrefix("donotreply")
    }
}
