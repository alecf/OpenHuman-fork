import Foundation
import MailModel
import Observation

public enum SnippetTrigger: Hashable, Sendable {
    case openPicker(range: Range<Int>, query: String)
    case expand(range: Range<Int>, shortcut: String)

    public static func detect(in text: String, caret: Int, shortcuts: Set<String>) -> SnippetTrigger? {
        let u = Array(text.utf16)
        guard caret >= 2, caret <= u.count else { return nil }
        let semicolon = utf16Unit(";")
        let typed = u[caret - 1]
        if typed == semicolon, u[caret - 2] == semicolon, isWordStart(u, caret - 2) {
            return .openPicker(range: (caret - 2)..<caret, query: "")
        }
        if typed == utf16Unit(" ") || typed == utf16Unit("\t") {
            guard let start = triggerStart(u, before: caret - 1) else { return nil }
            let name = String(decoding: u[(start + 2)..<(caret - 1)], as: UTF16.self).lowercased()
            guard !name.isEmpty, shortcuts.contains(name) else { return nil }
            return .expand(range: start..<caret, shortcut: name)
        }
        return nil
    }

    public static func pendingQuery(in text: String, caret: Int) -> (range: Range<Int>, query: String)? {
        let u = Array(text.utf16)
        guard caret <= u.count, let start = triggerStart(u, before: caret) else { return nil }
        return (start..<caret, String(decoding: u[(start + 2)..<caret], as: UTF16.self))
    }

    static func triggerStart(_ u: [UInt16], before end: Int) -> Int? {
        var i = end
        while i > 0, isNameChar(u[i - 1]) { i -= 1 }
        guard i >= 2, u[i - 1] == utf16Unit(";"), u[i - 2] == utf16Unit(";"), isWordStart(u, i - 2) else {
            return nil
        }
        return i - 2
    }

    static func isWordStart(_ u: [UInt16], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = u[index - 1]
        return previous == 0x20 || previous == 0x09 || previous == 0x0A || previous == 0x0D || previous == 0xA0
            || previous == 0x2028 || previous == 0x2029 || previous == utf16Unit("(")
    }

    static func isNameChar(_ c: UInt16) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2D
    }
}

@MainActor @Observable
public final class SnippetPickerModel {
    public struct Row: Identifiable, Hashable, Sendable {
        public let snippet: SnippetInfo
        public let preview: String
        public var id: String { snippet.id }
    }

    public var query = "" { didSet { refresh() } }
    public private(set) var rows: [Row] = []
    public private(set) var cursor = 0
    public private(set) var isClosed = false
    public static let emptyText = String(localized: "No snippets yet. Create one in Settings › Snippets or ⌘K → New snippet.")
    public static let maxRows = 8

    @ObservationIgnored private var all: [SnippetInfo]
    @ObservationIgnored private let onChoose: @MainActor (SnippetInfo) -> Void
    @ObservationIgnored private let onClose: @MainActor () -> Void

    public init(snippets: [SnippetInfo], query: String = "", onChoose: @escaping @MainActor (SnippetInfo) -> Void,
                onClose: @escaping @MainActor () -> Void = {}) {
        self.all = snippets
        self.query = query
        self.onChoose = onChoose
        self.onClose = onClose
        refresh()
    }

    public var isEmpty: Bool { all.isEmpty }

    public func update(snippets: [SnippetInfo]) {
        all = snippets
        refresh()
    }

    public func moveCursor(by delta: Int) {
        guard !rows.isEmpty else { return }
        cursor = min(max(cursor + delta, 0), rows.count - 1)
    }

    public func confirm() {
        guard rows.indices.contains(cursor) else { return }
        choose(rows[cursor].snippet)
    }

    public func choose(_ snippet: SnippetInfo) {
        guard !isClosed else { return }
        isClosed = true
        onChoose(snippet)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        onClose()
    }

    private func refresh() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let ranked = all.map { snippet -> (SnippetInfo, Int) in
            (snippet, Self.score(snippet, query: q))
        }
        .filter { q.isEmpty || $0.1 > 0 }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.useCount != rhs.0.useCount { return lhs.0.useCount > rhs.0.useCount }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        rows = ranked.prefix(Self.maxRows).map { Row(snippet: $0.0, preview: Self.preview($0.0.bodyHTML)) }
        cursor = min(cursor, max(rows.count - 1, 0))
    }

    static func score(_ snippet: SnippetInfo, query: String) -> Int {
        guard !query.isEmpty else { return 1 }
        let name = snippet.name.lowercased()
        if let shortcut = snippet.shortcut?.lowercased() {
            if shortcut == query { return 100 }
            if shortcut.hasPrefix(query) { return 80 }
        }
        if name.hasPrefix(query) { return 60 }
        if name.contains(query) { return 40 }
        if preview(snippet.bodyHTML).lowercased().contains(query) { return 10 }
        return 0
    }

    public static func preview(_ html: String) -> String {
        let text = html.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        return QuoteSplit.decodeEntities(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
