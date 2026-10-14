import Foundation
import MailModel

public struct ReplySuggestion: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case quickReply
        case scheduling(SchedulingOption)
        case busy
        case createEvent
        case suggestTimes
    }

    public let id: String
    public let kind: Kind
    public let label: String
    public let body: String?
    public let help: String
    public let linkHostsAddedByAI: [String]

    public init(id: String, kind: Kind, label: String, body: String?, help: String, linkHostsAddedByAI: [String] = []) {
        self.id = id
        self.kind = kind
        self.label = label
        self.body = body
        self.help = help
        self.linkHostsAddedByAI = linkHostsAddedByAI
    }

    public var isReply: Bool { body != nil }
    public var isWarning: Bool { kind == .busy }

    public var schedulingOption: SchedulingOption? {
        if case .scheduling(let option) = kind { option } else { nil }
    }

    func quickReply(id: Int) -> QuickReply {
        QuickReply(id: id, label: label, body: body ?? "", linkHostsAddedByAI: linkHostsAddedByAI)
    }
}

public enum ReplySuggestions {
    public static let limit = 5

    public static func merge(scheduling: [ReplySuggestion], quickReplies: [QuickReply],
                             limit: Int = limit) -> [ReplySuggestion] {
        var out = scheduling
        let labels = Set(scheduling.map { normalized($0.label) })
        var bodies = Set(scheduling.compactMap { $0.body.map(normalized) })
        let decided = scheduling.contains { $0.kind == .busy || $0.schedulingOption == .accept }
        let asks = scheduling.contains { $0.schedulingOption == .askForOtherTimes }
        for reply in quickReplies {
            let text = reply.label + "\n" + reply.body
            if decided, acceptsTime(text) { continue }
            if asks, asksForOtherTimes(text) { continue }
            let label = normalized(reply.label)
            let body = normalized(reply.body)
            guard !body.isEmpty, !labels.contains(label), !bodies.contains(body) else { continue }
            bodies.insert(body)
            out.append(ReplySuggestion(id: "ai.\(reply.id)", kind: .quickReply, label: reply.label, body: reply.body,
                                       help: tooltip(reply.body), linkHostsAddedByAI: reply.linkHostsAddedByAI))
        }
        return Array(out.prefix(max(0, limit)))
    }

    public static func acceptsTime(_ text: String) -> Bool {
        let words = normalized(text)
        return acceptPhrases.contains { words.contains($0) }
    }

    public static func asksForOtherTimes(_ text: String) -> Bool {
        let words = normalized(text)
        return otherTimesPhrases.contains { words.contains($0) }
    }

    public static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static let acceptPhrases = [
        "works for me", "that works", "this works", "works great", "works well",
        "works perfectly", "sounds good", "sounds great", "sounds perfect", "see you then", "see you there",
        "see you tomorrow", "i'll be there", "i will be there", "count me in", "i can make it", "i can make that",
        "confirmed", "i'm free then", "i am free then", "looking forward to it", "that time is fine",
        "let's do it", "let's do that",
    ]

    static let otherTimesPhrases = [
        "other time", "another time", "different time", "alternative time", "other day", "another day",
        "reschedule", "find a time", "find another", "what times work", "when works", "when are you free",
        "when would work", "other slots",
    ]

    static func tooltip(_ body: String) -> String {
        body.split(whereSeparator: \.isNewline).prefix(2).joined(separator: "\n")
    }
}

extension ComposeManager {
    @discardableResult
    public func useSuggestion(_ text: String, thread: ThreadKey, message: MessageKey, auto: Bool,
                              scheduling: SchedulingReplyContext? = nil) async -> ComposeSession? {
        let open = sessions.last { $0.thread == thread && $0.isOpen && ($0.mode == .reply || $0.mode == .replyAll) }
        // Why: a suggestion never goes into a reply that already holds the user's own text
        if let open, open.holdsUserText {
            open.notice = ComposeSession.Notice(.info, String(localized: "Suggestions go into an empty reply only. Use ⌘J to edit your text."))
            return nil
        }
        guard let session = openReply(thread, mode: open?.mode ?? .reply, message: message) else { return nil }
        await session.preparation?.value
        guard session.isOpen, !session.holdsUserText else { return nil }
        if session.insertSuggestedReply(text) {
            session.isAutoDraft = auto
            session.scheduling = scheduling
        } else if let scheduling {
            session.scheduling = scheduling
        }
        session.requestFocus()
        return session
    }
}
