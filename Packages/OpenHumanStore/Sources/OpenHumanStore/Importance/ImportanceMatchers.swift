import Foundation
import OpenHumanCore
import Synchronization

public enum ImportanceMatchers {
    private static let registry = Mutex<[String: any ImportanceMatcher]>([
        KeywordImportanceMatcher.matcherID: KeywordImportanceMatcher(),
        ThreadImportanceMatcher.matcherID: ThreadImportanceMatcher(),
    ])

    static let builtInIDs: Set<String> = [KeywordImportanceMatcher.matcherID, ThreadImportanceMatcher.matcherID]

    public static func register(_ matcher: any ImportanceMatcher) {
        guard ImportanceRuleValue.isMatcherID(matcher.id), matcher.id != ThreadImportanceMatcher.matcherID else { return }
        registry.withLock { $0[matcher.id] = matcher }
    }

    public static func unregister(id: String) {
        guard !builtInIDs.contains(id) else { return }
        registry.withLock { _ = $0.removeValue(forKey: id) }
    }

    public static func matcher(id: String) -> (any ImportanceMatcher)? {
        registry.withLock { $0[id] }
    }

    public static var registeredIDs: [String] { registry.withLock { $0.keys.sorted() } }
}

public struct KeywordImportanceMatcher: ImportanceMatcher {
    public static let matcherID = "keyword"
    public var id: String { Self.matcherID }
    public var readsText: Bool { true }

    public init() {}

    public func matches(_ facts: ImportanceFacts, argument: String) -> Bool {
        guard let keyword = try? ImportanceRuleValue.normalize(.keyword, argument) else { return false }
        return facts.messages.contains { m in
            !m.isFromMe && (TextSearch.contains(m.subject.lowercased(), keyword)
                || TextSearch.contains((m.text ?? "").lowercased(), keyword))
        }
    }
}

public struct ThreadImportanceMatcher: ImportanceMatcher {
    public static let matcherID = "thread"
    public var id: String { Self.matcherID }
    public var readsText: Bool { false }

    public init() {}

    public func matches(_ facts: ImportanceFacts, argument: String) -> Bool {
        guard !argument.isEmpty, let thread = facts.threadID else { return false }
        return thread.rawValue == argument
    }

    public static func value(for thread: GmailThreadID) -> String { matcherID + ":" + thread.rawValue }

    public static func thread(inValue value: String) -> GmailThreadID? {
        let (id, argument) = ImportanceRuleValue.matcherParts(value)
        guard id.lowercased() == matcherID, !argument.isEmpty else { return nil }
        return GmailThreadID(argument)
    }
}

enum ImportanceRuleValue {
    static let maxKeyword = 200
    static let maxLabel = 500
    static let maxMatcherArgument = 200

    static func normalize(_ kind: ImportanceMatchKind, _ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .sender:
            var address = trimmed
            if let open = address.lastIndex(of: "<"), let close = address[open...].firstIndex(of: ">") {
                address = String(address[address.index(after: open)..<close])
            }
            if address.lowercased().hasPrefix("mailto:") { address = String(address.dropFirst("mailto:".count)) }
            address = address.trimmingCharacters(in: .whitespaces).lowercased()
            guard let at = address.lastIndex(of: "@"), at != address.startIndex, address.index(after: at) != address.endIndex,
                  !address.contains(where: \.isWhitespace) else {
                throw StoreError.conflict("a sender rule needs an address like name@example.com")
            }
            return address
        case .domain:
            var domain = trimmed.lowercased()
            if domain.hasPrefix("@") { domain.removeFirst() }
            while domain.hasSuffix(".") { domain.removeLast() }
            guard domain.contains("."), !domain.contains("@"), !domain.hasPrefix("."), !domain.contains(".."),
                  !domain.contains(where: \.isWhitespace) else {
                throw StoreError.conflict("a domain rule needs a domain like example.com")
            }
            return domain
        case .keyword:
            let keyword = SearchTextNormalizer.normalizeField(trimmed).lowercased()
            guard !keyword.isEmpty, keyword.count <= maxKeyword else {
                throw StoreError.conflict("a keyword rule needs 1 to \(maxKeyword) characters")
            }
            return keyword
        case .label:
            guard !trimmed.isEmpty, trimmed.count <= maxLabel else { throw StoreError.conflict("a label rule needs a label name") }
            return trimmed
        case .matcher:
            let (id, argument) = matcherParts(trimmed)
            let matcherID = id.trimmingCharacters(in: .whitespaces).lowercased()
            guard isMatcherID(matcherID), argument.count <= maxMatcherArgument else {
                throw StoreError.conflict("a matcher rule needs an id like keyword or keyword:invoice")
            }
            return argument.isEmpty ? matcherID : matcherID + ":" + argument
        }
    }

    static func matcherParts(_ value: String) -> (id: String, argument: String) {
        guard let colon = value.firstIndex(of: ":") else { return (value, "") }
        return (String(value[..<colon]), String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    static func isMatcherID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, ("a"..."z").contains(first), id.unicodeScalars.count <= 64 else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    static func domain(of email: String, matches domain: String) -> Bool {
        Self.domain(ofLowercased: email.lowercased(), matches: domain)
    }

    static func domain(ofLowercased e: String, matches domain: String) -> Bool {
        guard let at = e.utf8.lastIndex(of: UInt8(ascii: "@")) else { return false }
        let d = e.utf8[e.utf8.index(after: at)...]
        guard d.count >= domain.utf8.count else { return false }
        if d.count == domain.utf8.count { return d.elementsEqual(domain.utf8) }
        let start = d.index(d.endIndex, offsetBy: -domain.utf8.count)
        return d[d.index(before: start)] == UInt8(ascii: ".") && d[start...].elementsEqual(domain.utf8)
    }
}

extension ImportanceReason {
    public var reasonText: String {
        var text: String
        switch basis {
        case .rule:
            guard let rule else { return "no rule matched" }
            let d = rule.definition
            let verb = d.effect == .neverImportant ? "never important" : "always important"
            switch d.kind {
            case .sender, .domain: text = "\(verb) from \(d.value)"
            case .keyword: text = "\(verb) when it mentions \u{201C}\(d.value)\u{201D}"
            case .label: text = "\(verb) with the label \(d.value)"
            case .matcher where ThreadImportanceMatcher.thread(inValue: d.value) != nil:
                text = d.effect == .neverImportant ? "moved to Other (this conversation only)"
                    : "moved to Important (this conversation only)"
            case .matcher: text = "\(verb) by the \(d.value) rule"
            }
            if d.source == .ai { text += " (suggested by AI)" }
        case .importanceSplit:
            let ruleText = importanceSplitRuleText ?? ""
            text = ruleText == "is:important" ? "Gmail marked it important" : "matches the importance rule \(ruleText)"
        case .none:
            text = placementSplitID != nil ? "matches the \(placementName) split" : "no rule or split matched"
        }
        if !exemptions.isEmpty { text += "; removed from a split by your rule" }
        if gmailImportant, importance != .important { text += "; Gmail marks it important" }
        return text
    }

    public var line: String {
        isInInbox ? "In \(placementName): \(reasonText)" : "Not in the inbox: \(reasonText)"
    }
}

extension ImportanceRulesDocument {
    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public init(json: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let document: ImportanceRulesDocument
        do { document = try decoder.decode(ImportanceRulesDocument.self, from: json) } catch {
            throw StoreError.conflict("the importance rules are not readable")
        }
        guard document.version == 1 else {
            throw StoreError.conflict("importance rules version \(document.version) is not supported")
        }
        self = document
    }
}
