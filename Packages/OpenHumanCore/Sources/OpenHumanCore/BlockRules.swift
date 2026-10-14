import Foundation

public enum BlockDisposition: String, Codable, Sendable, Hashable, CaseIterable {
    case archive
    case trash

    public var title: String {
        switch self {
        case .archive: "Archive and mark read"
        case .trash: "Move to Trash"
        }
    }
}

public struct BlockRule: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case sender
        case domain
    }

    public var id: String { "\(kind.rawValue):\(value)" }
    public let kind: Kind
    public let value: String
    public var disposition: BlockDisposition?
    public let createdAt: Date

    public init?(kind: Kind, value: String, disposition: BlockDisposition? = nil, createdAt: Date) {
        let normalized: String? = switch kind {
        case .sender: BlockMatcher.normalizedAddress(value)
        case .domain: BlockMatcher.normalizedDomain(value)
        }
        guard let normalized else { return nil }
        self.kind = kind
        self.value = normalized
        self.disposition = disposition
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case kind, value, disposition, created }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let raw = try c.decode(String.self, forKey: .value)
        guard let normalized = (kind == .sender ? BlockMatcher.normalizedAddress(raw) : BlockMatcher.normalizedDomain(raw)) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "not a usable block value")
        }
        self.kind = kind
        value = normalized
        disposition = try c.decodeIfPresent(BlockDisposition.self, forKey: .disposition)
        createdAt = Date(timeIntervalSince1970: try c.decodeIfPresent(Double.self, forKey: .created) ?? 0)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(value, forKey: .value)
        try c.encodeIfPresent(disposition, forKey: .disposition)
        try c.encode(createdAt.timeIntervalSince1970, forKey: .created)
    }
}

public enum BlockSettingNames {
    public static let rules = "block.rules"
    public static let defaultDisposition = "block.default_disposition"
    public static let checkedThrough = "block.checked_through"
}

public enum BlockOutcome: Sendable, Hashable {
    case keep
    case archive
    case trash
}

public enum BlockMatcher {

    public static func normalizedAddress(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            text = String(text[text.index(after: open)..<close])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.filter({ $0 == "@" }).count == 1,
              !text.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "," || $0 == "<" || $0 == ">" }) else { return nil }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        var local = String(parts[0])
        if let plus = local.firstIndex(of: "+") { local = String(local[..<plus]) }
        guard !local.isEmpty, let domain = normalizedDomain(String(parts[1])) else { return nil }
        return "\(local)@\(domain)"
    }

    public static func normalizedDomain(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("@") { text.removeFirst() }
        while text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty, text.contains("."),
              !text.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "@" || $0 == "," || $0 == "<" || $0 == ">" })
        else { return nil }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return text
    }

    public static func domain(of address: String) -> String? {
        normalizedAddress(address).map { String($0[$0.index(after: $0.firstIndex(of: "@")!)...]) }
    }


    public static func matches(_ rule: BlockRule, address: String) -> Bool {
        guard let address = normalizedAddress(address) else { return false }
        switch rule.kind {
        case .sender:
            return address == rule.value
        case .domain:
            guard let domain = domain(of: address) else { return false }
            return domain == rule.value || domain.hasSuffix("." + rule.value)
        }
    }

    public static func firstMatch(in rules: [BlockRule], address: String) -> BlockRule? {
        let matching = rules.filter { matches($0, address: address) }
        if let sender = matching.first(where: { $0.kind == .sender }) { return sender }
        return matching.filter { $0.kind == .domain }.max { $0.value.count < $1.value.count }
    }


    public static func decide(from: String?, labelIDs: [String], rules: [BlockRule],
                              defaultDisposition: BlockDisposition) -> BlockOutcome {
        guard let from, labelIDs.contains("INBOX"),
              !labelIDs.contains("SENT"), !labelIDs.contains("DRAFT"), !labelIDs.contains("TRASH"),
              !labelIDs.contains("SPAM"),
              let rule = firstMatch(in: rules, address: from) else { return .keep }
        return (rule.disposition ?? defaultDisposition) == .trash ? .trash : .archive
    }

    public static func address(fromHeader value: String) -> String? { normalizedAddress(value) }


    public static func sentToQuery(kind: BlockRule.Kind, value: String) -> String? {
        guard let target = target(kind: kind, value: value) else { return nil }
        return "in:sent (to:\"\(target)\" OR cc:\"\(target)\" OR bcc:\"\(target)\")"
    }

    public static func cleanupQuery(kind: BlockRule.Kind, value: String) -> String? {
        guard let target = target(kind: kind, value: value) else { return nil }
        return "from:\"\(target)\" in:inbox"
    }

    public static func showQuery(kind: BlockRule.Kind, value: String) -> String? {
        guard let target = target(kind: kind, value: value) else { return nil }
        return "from:\"\(target)\""
    }

    public static func recheckQuery(kind: BlockRule.Kind, value: String, since: Date) -> String? {
        guard let target = target(kind: kind, value: value) else { return nil }
        let seconds = max(Int64(since.timeIntervalSince1970.rounded(.down)), 100_000_000)
        return "from:\"\(target)\" after:\(seconds) in:anywhere"
    }

    public static func coversAny(_ rule: BlockRule, senders: [String]) -> Bool {
        senders.contains { matches(rule, address: $0) }
    }

    private static func target(kind: BlockRule.Kind, value: String) -> String? {
        switch kind {
        case .sender: normalizedAddress(value)
        case .domain: normalizedDomain(value)
        }
    }
}
