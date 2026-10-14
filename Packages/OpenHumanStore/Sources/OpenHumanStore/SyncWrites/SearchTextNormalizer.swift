import Foundation

enum SearchTextNormalizer {
    static let maxBodyBytes = 32 * 1024
    static let quoteDropMinimum = 200

    static func normalizeBody(_ text: String) -> String {
        let lines = splitLines(stripInvisible(text.precomposedStringWithCanonicalMapping))
        let unquoted = collapse(lines.filter { !isQuoted($0) }.joined(separator: "\n"))
        let body = unquoted.count >= quoteDropMinimum ? unquoted : collapse(lines.joined(separator: "\n"))
        return cap(body, maxBytes: maxBodyBytes)
    }

    static func normalizeField(_ text: String) -> String {
        cap(collapse(stripInvisible(text.precomposedStringWithCanonicalMapping)), maxBytes: maxBodyBytes)
    }

    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x061C, 0x180E, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func stripInvisible(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isInvisible) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.lazy.filter { !isInvisible($0) })
        return String(scalars)
    }

    private static func splitLines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false) { $0.isNewline }
    }

    private static func isQuoted(_ line: Substring) -> Bool {
        line.first { !$0.isWhitespace } == ">"
    }

    private static func collapse(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for c in text {
            if c.isWhitespace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(c)
            }
        }
        return out
    }

    static func cap(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            if bytes + size > maxBytes { break }
            bytes += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}
