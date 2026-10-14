import Foundation
import MailModel
import Observation
import OpenHumanCore

public enum MentionTrigger {
    public static func pending(in text: String, caret: Int) -> (range: Range<Int>, query: String)? {
        let u = Array(text.utf16)
        guard caret > 0, caret <= u.count else { return nil }
        var i = caret
        while i > 0, isQueryUnit(u[i - 1]) { i -= 1 }
        guard i > 0, caret - i <= maxQueryLength, isTrigger(u[i - 1]), isWordStart(u, i - 1) else { return nil }
        return ((i - 1)..<caret, String(decoding: u[i..<caret], as: UTF16.self))
    }

    public static let maxQueryLength = 40

    public static func keyMayPick(query: String, highlightMoved: Bool) -> Bool {
        if highlightMoved { return true }
        return query.count >= 2 && !query.contains { $0.isNumber || $0 == "_" }
    }

    static func isTrigger(_ c: UInt16) -> Bool { c == 0x40 || c == 0x2B }

    static func isWordStart(_ u: [UInt16], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = u[index - 1]
        return previous == 0x20 || previous == 0x09 || previous == 0x0A || previous == 0x0D || previous == 0xA0
            || previous == 0x2028 || previous == 0x2029 || previous == 0x28 || previous == 0x5B
    }

    static func isQueryUnit(_ c: UInt16) -> Bool {
        if c >= 0x80 { return c != 0xA0 && c != 0x2028 && c != 0x2029 && c != 0x200B }
        return (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)
            || c == 0x2E || c == 0x5F || c == 0x2D || c == 0x27
    }
}

public struct MentionRow: Identifiable, Hashable, Sendable {
    public let address: EmailAddress
    public let matchedPrefixLength: Int

    public var id: String { address.email.lowercased() }

    public var displayName: String { MentionEdit.insertedName(for: address) }

    public var emailMatched: String { String(address.email.prefix(matchedPrefixLength)) }
    public var emailRest: String { String(address.email.dropFirst(matchedPrefixLength)) }

    public init(address: EmailAddress, matchedPrefixLength: Int = 0) {
        self.address = address
        self.matchedPrefixLength = matchedPrefixLength
    }
}

public enum MentionRanking {
    public static func rank(_ candidates: [EmailAddress], query: String, limit: Int) -> [MentionRow] {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        var seen = Set<String>()
        var scored: [(tier: Int, index: Int, row: MentionRow)] = []
        for (index, candidate) in candidates.enumerated() {
            let key = candidate.email.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let email = fold(candidate.email)
            let name = fold(candidate.name ?? "")
            let tier: Int
            if q.isEmpty || email.hasPrefix(q) || name.hasPrefix(q) {
                tier = 0
            } else if name.split(whereSeparator: { $0 == " " || $0 == "-" }).contains(where: { $0.hasPrefix(q) }) {
                tier = 1
            } else {
                continue
            }
            let covered = !q.isEmpty && email.hasPrefix(q) ? (query.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).length : 0
            scored.append((tier, index, MentionRow(address: candidate, matchedPrefixLength: covered)))
        }
        scored.sort { ($0.tier, $0.index) < ($1.tier, $1.index) }
        return Array(scored.prefix(max(limit, 0)).map(\.row))
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

public enum MentionEdit {
    public static func insertedName(for address: EmailAddress) -> String {
        var name = (address.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? address.email : name
    }

    public static func apply(to text: String, replacing range: Range<Int>, with address: EmailAddress)
        -> (text: String, caret: Int)? {
        let ns = text as NSString
        guard range.lowerBound >= 0, range.upperBound <= ns.length else { return nil }
        let name = insertedName(for: address)
        let result = ns.replacingCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: name)
        return (result, range.lowerBound + (name as NSString).length)
    }
}

@MainActor @Observable
public final class MentionPickerModel {
    public private(set) var rows: [MentionRow]
    public private(set) var cursor = 0
    public private(set) var isClosed = false
    public private(set) var query: String?
    public private(set) var isStale = false
    public private(set) var highlightMoved = false
    public static let maxRows = 6

    @ObservationIgnored private let onChoose: @MainActor (MentionRow) -> Void
    @ObservationIgnored private let onClose: @MainActor () -> Void

    public init(rows: [MentionRow], query: String? = nil, onChoose: @escaping @MainActor (MentionRow) -> Void,
                onClose: @escaping @MainActor () -> Void = {}) {
        self.rows = rows
        self.query = query
        self.onChoose = onChoose
        self.onClose = onClose
    }

    public func setRows(_ new: [MentionRow], query: String? = nil) {
        rows = new
        cursor = 0
        isStale = false
        highlightMoved = false
        if let query { self.query = query }
    }

    public func markStale() { isStale = true }

    public func moveCursor(by delta: Int) {
        guard !rows.isEmpty else { return }
        cursor = min(max(cursor + delta, 0), rows.count - 1)
        highlightMoved = true
    }

    @discardableResult
    public func confirm() -> Bool {
        guard !isStale, rows.indices.contains(cursor),
              query.map({ MentionTrigger.keyMayPick(query: $0, highlightMoved: highlightMoved) }) ?? true else {
            return false
        }
        choose(rows[cursor])
        return true
    }

    public func choose(_ row: MentionRow) {
        guard !isClosed else { return }
        isClosed = true
        onChoose(row)
        onClose()
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        onClose()
    }
}
