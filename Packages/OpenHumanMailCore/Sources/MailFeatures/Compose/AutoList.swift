import Foundation

public enum AutoList {
    public static let numberRange = 1...999
    public static let maxPlainIndent = 24

    public enum Marker: Hashable, Sendable {
        case bullet(Character)
        case number(Int)

        public var isOrdered: Bool {
            if case .number = self { return true }
            return false
        }

        public var number: Int {
            if case .number(let n) = self { return n }
            return 1
        }

        public var text: String {
            switch self {
            case .bullet(let c): String(c) + " "
            case .number(let n): "\(n). "
            }
        }

        public var next: Marker {
            if case .number(let n) = self { return .number(n + 1) }
            return self
        }
    }

    public struct Trigger: Hashable, Sendable {
        public let marker: Marker
        public let length: Int

        public var isOrdered: Bool { marker.isOrdered }
        public var start: Int { marker.number }
    }

    public struct PlainItem: Hashable, Sendable {
        public let indent: Int
        public let marker: Marker
        public let prefixLength: Int
        public let content: String

        public var isEmpty: Bool { content.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public enum PlainEdit: Hashable, Sendable {
        case newItem(String)
        case removeMarker(length: Int)
        case indent
        case outdent
    }

    public static func marker(atStartOf text: String) -> (marker: Marker, length: Int)? {
        let units = Array(text.utf16.prefix(8))
        guard units.count >= 2 else { return nil }
        if units[0] == 0x2D || units[0] == 0x2A {
            guard units[1] == 0x20 else { return nil }
            return (.bullet(units[0] == 0x2D ? "-" : "*"), 2)
        }
        var digits = 0
        while digits < units.count, (0x30...0x39).contains(units[digits]) { digits += 1 }
        guard (1...3).contains(digits), units.count >= digits + 2, units[digits] == 0x2E, units[digits + 1] == 0x20 else {
            return nil
        }
        let value = units[0..<digits].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        guard numberRange.contains(value) else { return nil }
        return (.number(value), digits + 2)
    }

    public static func trigger(line: String, caret: Int, isQuoted: Bool, isSignature: Bool) -> Trigger? {
        guard !isQuoted, !isSignature, let found = marker(atStartOf: line), found.length == caret else { return nil }
        let typed = NSRange(location: 0, length: found.length)
        guard !ProtectedTextRanges.touches(typed, ProtectedTextRanges.find(in: line)) else { return nil }
        return Trigger(marker: found.marker, length: found.length)
    }

    public static func plainItem(_ line: String) -> PlainItem? {
        let indent = line.utf16.prefix { $0 == 0x20 }.count
        let rest = (line as NSString).substring(from: indent)
        guard let found = marker(atStartOf: rest) else { return nil }
        return PlainItem(indent: indent, marker: found.marker, prefixLength: indent + found.length,
                         content: (rest as NSString).substring(from: found.length))
    }

    public static func plainReturn(line: String, caret: Int, isQuoted: Bool, isSignature: Bool) -> PlainEdit? {
        guard !isQuoted, !isSignature, let item = plainItem(line), caret >= item.prefixLength else { return nil }
        if item.isEmpty { return item.indent > 0 ? .outdent : .removeMarker(length: item.prefixLength) }
        return .newItem(String(repeating: " ", count: item.indent) + item.marker.next.text)
    }

    public static func plainBackspace(line: String, caret: Int, isQuoted: Bool, isSignature: Bool) -> PlainEdit? {
        guard !isQuoted, !isSignature, let item = plainItem(line), caret == item.prefixLength else { return nil }
        return item.indent > 0 ? .outdent : .removeMarker(length: item.prefixLength)
    }

    public static func plainTab(line: String, caret: Int, outdent: Bool, isQuoted: Bool, isSignature: Bool) -> PlainEdit? {
        guard !isQuoted, !isSignature, let item = plainItem(line) else { return nil }
        if outdent { return .outdent }
        return caret == item.prefixLength ? .indent : nil
    }

    public static func reindented(_ lines: [String], at index: Int, outdent: Bool) -> String? {
        guard lines.indices.contains(index), let item = plainItem(lines[index]) else { return nil }
        let indent: Int
        if outdent {
            guard item.indent > 0 else { return nil }
            indent = parent(of: item, in: lines, before: index)?.indent ?? 0
        } else {
            let above = sibling(at: item.indent, in: lines, before: index)
            indent = item.indent + (above ?? item).marker.text.utf16.count
            guard indent <= maxPlainIndent else { return nil }
        }
        var marker = item.marker
        if item.marker.isOrdered {
            if let above = sibling(at: indent, in: lines, before: index), above.marker.isOrdered {
                marker = above.marker.next
            } else {
                marker = .number(1)
            }
        }
        return String(repeating: " ", count: indent) + marker.text + item.content
    }

    static func sibling(at indent: Int, in lines: [String], before index: Int) -> PlainItem? {
        var i = index - 1
        while i >= 0, let above = plainItem(lines[i]) {
            if above.indent == indent { return above }
            if above.indent < indent { return nil }
            i -= 1
        }
        return nil
    }

    static func parent(of item: PlainItem, in lines: [String], before index: Int) -> PlainItem? {
        var i = index - 1
        while i >= 0, let above = plainItem(lines[i]) {
            if above.indent < item.indent { return above }
            i -= 1
        }
        return nil
    }

    public static func isQuotedLine(_ line: String) -> Bool { line.hasPrefix(">") }

    public static func isSignatureDelimiter(_ line: String) -> Bool {
        let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
        return trimmed == "-- " || trimmed == "--"
    }

    public static func isInSignature(_ text: String, lineStart: Int) -> Bool {
        let ns = text as NSString
        guard lineStart > 0, lineStart <= ns.length else { return false }
        return ns.substring(to: lineStart).components(separatedBy: "\n").dropLast().contains(where: isSignatureDelimiter)
    }
}
