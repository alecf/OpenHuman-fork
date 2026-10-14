import Foundation
import OpenHumanCore

public typealias ParsedQuery = SearchQuery

extension SearchQuery {
    public var gmailQuery: String {
        SearchSerializer.serialize(terms, gmail: true)
    }

    public var canonicalText: String {
        SearchSerializer.serialize(terms, gmail: false)
    }

    var searchesBodies: Bool { terms.contains { SearchSerializer.touchesBody($0) } }
}

enum SearchSerializer {
    static func serialize(_ terms: [SearchTerm], gmail: Bool) -> String {
        terms.compactMap { term(for: $0, gmail: gmail) }.joined(separator: " ")
    }

    static func touchesBody(_ term: SearchTerm) -> Bool {
        switch term {
        case let .text(_, field): return field == nil || field == .body
        case let .not(inner): return touchesBody(inner)
        case let .or(items), let .and(items): return items.contains(where: touchesBody)
        default: return false
        }
    }

    static func term(for term: SearchTerm, gmail: Bool) -> String? {
        switch term {
        case let .text(text, field):
            switch field {
            case .subject: return "subject:" + value(text)
            case .attachments: return "filename:" + value(text)
            default: return value(text)
            }
        case let .address(field, text): return "\(field.rawValue):" + value(text)
        case let .label(name):
            if name.hasPrefix("CATEGORY_") {
                let category = name.dropFirst("CATEGORY_".count).lowercased()
                return "category:" + (category == "personal" ? "primary" : category)
            }
            return "label:" + value(gmail ? name.replacingOccurrences(of: " ", with: "-") : name)
        case let .mailbox(box):
            switch box {
            case .inbox: return "in:inbox"
            case .starred: return "is:starred"
            case .important: return "is:important"
            case .unread: return "is:unread"
            case .sent: return "in:sent"
            case .drafts: return "in:drafts"
            case .allMail: return gmail ? nil : "in:all"
            case .trash: return "in:trash"
            case .spam: return "in:spam"
            case .snoozed: return "in:snoozed"
            case .scheduled: return "in:scheduled"
            case .reminders: return gmail ? nil : "in:reminders"
            case .done: return gmail ? nil : "in:done"
            case .waiting: return gmail ? nil : "in:waiting"
            }
        case .isFlag(.event): return gmail ? gmailEventQuery : "is:event"
        case let .isFlag(flag): return "is:\(flag.rawValue)"
        case let .has(has):
            switch has {
            case .attachment: return "has:attachment"
            case .invite: return gmail ? "filename:ics" : "has:invite"
            case .userLabels: return "has:userlabels"
            }
        case let .filename(name): return "filename:" + value(name)
        case let .before(date): return "before:\(Int64(date.timeIntervalSince1970))"
        case let .after(date): return "after:\(Int64(date.timeIntervalSince1970))"
        case let .larger(n): return "larger:\(n)"
        case let .smaller(n): return "smaller:\(n)"
        case let .listID(id): return "list:" + value(id)
        case let .rfc822msgid(id): return "rfc822msgid:" + value(id)
        case .anywhere: return "in:anywhere"
        case let .not(inner):
            return self.term(for: inner, gmail: gmail).map { "-" + $0 }
        case let .or(items):
            let parts = items.compactMap { self.term(for: $0, gmail: gmail) }
            return parts.isEmpty ? nil : "(" + parts.joined(separator: " OR ") + ")"
        case let .and(items):
            let parts = items.compactMap { self.term(for: $0, gmail: gmail) }
            return parts.isEmpty ? nil : "(" + parts.joined(separator: " ") + ")"
        }
    }

    static let gmailEventQuery: String = {
        var parts = ["filename:ics"]
        parts += EventMailSignals.calendarSenders.sorted().map { "from:" + $0 }
        parts += EventMailSignals.invitationSubjectPrefixes.map { "subject:" + value(String($0.dropLast())) }
        parts += EventMailSignals.platformDomains.map { "from:" + $0 }
        return "(" + parts.joined(separator: " OR ") + ")"
    }()

    static func value(_ text: String) -> String {
        needsQuoting(text) ? "\"" + text.replacingOccurrences(of: "\"", with: " ") + "\"" : text
    }

    private static func needsQuoting(_ text: String) -> Bool {
        if text.isEmpty || text.hasPrefix("-") { return true }
        if ["OR", "AND", "NOT", "AROUND"].contains(text) || text.hasPrefix("AROUND_") { return true }
        if text.unicodeScalars.contains(where: { $0.properties.isWhitespace || "(){}\"".unicodeScalars.contains($0) }) { return true }
        if let colon = text.firstIndex(of: ":"), SearchParser.operators.contains(text[..<colon].lowercased()) { return true }
        return false
    }
}
