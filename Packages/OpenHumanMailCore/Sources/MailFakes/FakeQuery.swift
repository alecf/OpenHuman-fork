import Foundation
import MailModel

indirect enum FakeQuery: Sendable, Hashable {
    enum Mode: Sendable { case split, search }

    case term(key: String?, value: String)
    case not(FakeQuery)
    case and([FakeQuery])
    case or([FakeQuery])

    struct Facts {
        var senders: [String]
        var recipients: [String]
        var subject: String
        var text: String
        var labelNames: Set<String>
        var listIDs: [String]
        var flags: Set<String>
        var has: Set<String>
        var mailboxes: Set<String>
    }

    static let splitKeys: Set<String> = ["from", "to", "label", "category", "is", "has", "list", "subject"]
    static let searchKeys: Set<String> = splitKeys.union(["cc", "bcc", "in"])
    static let isValues: Set<String> = ["important", "starred", "unread", "read", "snoozed", "draft", "event"]
    static let hasValues: Set<String> = ["attachment", "invite", "userlabels"]
    static let inValues: Set<String> = ["inbox", "sent", "trash", "spam", "anywhere", "snoozed", "drafts", "starred",
                                        "important", "scheduled", "reminders", "all"]

    static func parse(_ text: String, mode: Mode) throws -> FakeQuery {
        var parser = Parser(tokens: try tokenize(text), mode: mode)
        let query = try parser.orExpression(defaultKey: nil)
        guard parser.atEnd else { throw MailPortError.invalidQuery("unexpected \(parser.peek.map(String.init(describing:)) ?? "end")") }
        return query
    }

    var includesTrashOrSpam: Bool {
        switch self {
        case .term(let key, let value): key == "in" && ["trash", "spam", "anywhere"].contains(value)
        case .not: false
        case .and(let parts), .or(let parts): parts.contains(where: \.includesTrashOrSpam)
        }
    }

    func matches(_ facts: Facts) -> Bool {
        switch self {
        case .not(let inner): return !inner.matches(facts)
        case .and(let parts): return parts.allSatisfy { $0.matches(facts) }
        case .or(let parts): return parts.contains { $0.matches(facts) }
        case .term(nil, let value): return facts.text.contains(value)
        case .term(let key?, let value):
            switch key {
            case "from": return facts.senders.contains { Self.addressMatches($0, value) }
            case "to", "cc", "bcc": return facts.recipients.contains { Self.addressMatches($0, value) }
            case "subject": return facts.subject.contains(value)
            case "label": return facts.labelNames.contains(value) || facts.labelNames.contains(value.replacingOccurrences(of: "-", with: "/"))
            case "category": return FakeLabels.categories[value].map { facts.labelNames.contains($0.rawValue.lowercased()) } ?? false
            case "list": return facts.listIDs.contains { $0.contains(value) }
            case "is": return facts.flags.contains(value)
            case "has": return facts.has.contains(value)
            case "in": return value == "anywhere" || value == "all" ? true : facts.mailboxes.contains(value)
            default: return false
            }
        }
    }

    private static func addressMatches(_ address: String, _ value: String) -> Bool {
        address.contains(value)
    }

    enum Token: Sendable, Hashable, CustomStringConvertible {
        case open, close, minus, or, and
        case word(String)
        case phrase(String)
        var description: String {
            switch self {
            case .open: "("
            case .close: ")"
            case .minus: "-"
            case .or: "OR"
            case .and: "AND"
            case .word(let w): w
            case .phrase(let p): "\"\(p)\""
            }
        }
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var chars = Array(text)[...]
        while let c = chars.first {
            if c.isWhitespace { chars.removeFirst(); continue }
            if c == "(" { tokens.append(.open); chars.removeFirst(); continue }
            if c == ")" { tokens.append(.close); chars.removeFirst(); continue }
            if c == "-", let next = chars.dropFirst().first, !next.isWhitespace {
                tokens.append(.minus); chars.removeFirst(); continue
            }
            var word = ""
            var quotedOnly = c == "\""
            while let d = chars.first, !d.isWhitespace, d != "(", d != ")" {
                if d == "\"" {
                    chars.removeFirst()
                    guard let end = chars.firstIndex(of: "\"") else { throw MailPortError.invalidQuery("unclosed quote") }
                    word += String(chars[chars.startIndex..<end])
                    chars = chars[chars.index(after: end)...]
                    continue
                }
                quotedOnly = false
                word.append(d)
                chars.removeFirst()
            }
            if quotedOnly {
                tokens.append(.phrase(word))
                continue
            }
            switch word {
            case "OR", "|": tokens.append(.or)
            case "AND": tokens.append(.and)
            default: tokens.append(.word(word))
            }
        }
        return tokens
    }

    struct Parser {
        var tokens: [Token]
        let mode: Mode
        var index = 0

        var atEnd: Bool { index >= tokens.count }
        var peek: Token? { atEnd ? nil : tokens[index] }

        mutating func orExpression(defaultKey: String?) throws -> FakeQuery {
            var parts = [try andExpression(defaultKey: defaultKey)]
            while peek == .or {
                index += 1
                parts.append(try andExpression(defaultKey: defaultKey))
            }
            return parts.count == 1 ? parts[0] : .or(parts)
        }

        mutating func andExpression(defaultKey: String?) throws -> FakeQuery {
            var parts = [try unary(defaultKey: defaultKey)]
            while let next = peek, next != .or, next != .close {
                if next == .and { index += 1 }
                parts.append(try unary(defaultKey: defaultKey))
            }
            return parts.count == 1 ? parts[0] : .and(parts)
        }

        mutating func unary(defaultKey: String?) throws -> FakeQuery {
            guard let token = peek else { throw MailPortError.invalidQuery("missing term") }
            index += 1
            switch token {
            case .minus:
                return .not(try unary(defaultKey: defaultKey))
            case .open:
                let inner = try orExpression(defaultKey: defaultKey)
                guard peek == .close else { throw MailPortError.invalidQuery("missing )") }
                index += 1
                return inner
            case .word(let word):
                return try term(word, defaultKey: defaultKey)
            case .phrase(let text):
                if let key = defaultKey { return .term(key: key, value: text.lowercased()) }
                guard mode == .search else { throw MailPortError.invalidQuery("free text is not a split rule") }
                return .term(key: nil, value: text.lowercased())
            case .close, .or, .and:
                throw MailPortError.invalidQuery("unexpected \(token)")
            }
        }

        mutating func term(_ word: String, defaultKey: String?) throws -> FakeQuery {
            if let colon = word.firstIndex(of: ":") {
                let key = word[..<colon].lowercased()
                let value = String(word[word.index(after: colon)...]).lowercased()
                let allowed = mode == .split ? FakeQuery.splitKeys : FakeQuery.searchKeys
                guard allowed.contains(key) else { throw MailPortError.invalidQuery("unknown operator \(key):") }
                if value.isEmpty {
                    guard peek == .open else { throw MailPortError.invalidQuery("\(key): needs a value") }
                    index += 1
                    let inner = try orExpression(defaultKey: key)
                    guard peek == .close else { throw MailPortError.invalidQuery("missing )") }
                    index += 1
                    return inner
                }
                try Self.validate(key: key, value: value)
                return .term(key: key, value: value)
            }
            if let key = defaultKey {
                let value = word.lowercased()
                try Self.validate(key: key, value: value)
                return .term(key: key, value: value)
            }
            guard mode == .search else { throw MailPortError.invalidQuery("free text is not a split rule") }
            return .term(key: nil, value: word.lowercased())
        }

        static func validate(key: String, value: String) throws {
            switch key {
            case "is" where !FakeQuery.isValues.contains(value),
                 "has" where !FakeQuery.hasValues.contains(value),
                 "in" where !FakeQuery.inValues.contains(value),
                 "category" where FakeLabels.categories[value] == nil:
                throw MailPortError.invalidQuery("unknown value \(key):\(value)")
            default:
                return
            }
        }
    }
}
