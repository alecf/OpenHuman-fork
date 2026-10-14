import Foundation

public enum Untrusted {
    public static let tagName = "email_data"
    public static let nonceLength = 12
    public static let nonceReplacement = "[redacted]"
    static let escapedLessThan: Unicode.Scalar = "\u{2039}"
    static let nonceAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    static let protectedNames: [[[Unicode.Scalar]]] = [
        [Array("email".unicodeScalars), Array("data".unicodeScalars)],
        [Array("user".unicodeScalars), Array("instruction".unicodeScalars)],
        [Array("context".unicodeScalars)],
    ]

    public static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<nonceLength).map { _ in nonceAlphabet[Int.random(in: 0..<nonceAlphabet.count, using: &generator)] })
    }

    public static func render(_ parts: [UntrustedPart], nonce: String) -> String {
        parts.map { part in
            var open = "<\(tagName) nonce=\"\(nonce)\" id=\"\(attributeValue(part.id))\" kind=\"\(part.kind.rawValue)\""
            if let date = part.date { open += " date=\"\(date.formatted(.iso8601))\"" }
            open += ">"
            return open + "\n" + neutralize(part.text, nonce: nonce) + "\n" + closingTag(nonce: nonce)
        }.joined(separator: "\n")
    }

    public static func closingTag(nonce: String) -> String { "</\(tagName) nonce=\"\(nonce)\">" }

    public static func renderTrusted(_ parts: [TrustedPart], nonce: String) -> String {
        parts.map { part in
            let text = neutralize(part.text, nonce: nonce)
            switch part.kind {
            case .userInstruction:
                return "<user_instruction>\n\(text)\n</user_instruction>"
            case .userQuestion:
                return "<user_instruction kind=\"question\">\n\(text)\n</user_instruction>"
            case .userName, .today, .position, .userPreferences:
                return "<context kind=\"\(part.kind.rawValue)\">\(text)</context>"
            }
        }.joined(separator: "\n")
    }

    public static func neutralize(_ text: String, nonce: String) -> String {
        if isPlainASCII(text, nonce: nonce) { return text }
        let source = Array(text.unicodeScalars)
        let folded = FoldedText(source)
        let escapes = Set(delimiterStarts(in: folded).map { folded.origin[$0] })
        var nonceRanges: [ClosedRange<Int>] = []
        let foldedNonce = Array(FoldedText(nonce).scalars)
        for range in folded.occurrences(of: foldedNonce) {
            nonceRanges.append(folded.origin[range.lowerBound]...folded.origin[range.upperBound - 1])
        }
        if escapes.isEmpty && nonceRanges.isEmpty { return text }

        var out = String.UnicodeScalarView()
        var index = 0
        var rangeIndex = 0
        while index < source.count {
            if rangeIndex < nonceRanges.count, nonceRanges[rangeIndex].contains(index) {
                out.append(contentsOf: nonceReplacement.unicodeScalars)
                index = nonceRanges[rangeIndex].upperBound + 1
                rangeIndex += 1
                while rangeIndex < nonceRanges.count, nonceRanges[rangeIndex].upperBound < index { rangeIndex += 1 }
                continue
            }
            out.append(escapes.contains(index) ? escapedLessThan : source[index])
            index += 1
        }
        return String(out)
    }

    public static func containsDelimiterLookalike(_ text: String) -> Bool {
        if isPlainASCII(text, nonce: nil) { return false }
        return !delimiterStarts(in: FoldedText(text)).isEmpty
    }

    public static func containsNonce(_ text: String, nonce: String) -> Bool {
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            return text.range(of: nonce, options: [.caseInsensitive, .literal]) != nil
        }
        return !FoldedText(text).occurrences(of: Array(FoldedText(nonce).scalars)).isEmpty
    }

    static func isPlainASCII(_ text: String, nonce: String?) -> Bool {
        var sawLessThan = false
        for byte in text.utf8 {
            if byte >= 0x80 { return false }
            if byte == UInt8(ascii: "<") { sawLessThan = true }
        }
        if sawLessThan { return false }
        if let nonce, text.range(of: nonce, options: [.caseInsensitive, .literal]) != nil { return false }
        return true
    }

    static func delimiterStarts(in folded: FoldedText) -> [Int] {
        let scalars = folded.scalars
        var starts: [Int] = []
        for index in scalars.indices where scalars[index] == "<" {
            var cursor = skipSpaces(scalars, from: index + 1)
            if cursor < scalars.count, scalars[cursor] == "/" { cursor = skipSpaces(scalars, from: cursor + 1) }
            if protectedNames.contains(where: { matches(words: $0, in: scalars, at: cursor) }) { starts.append(index) }
        }
        return starts
    }

    private static func skipSpaces(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var cursor = start
        while cursor < scalars.count, scalars[cursor].properties.isWhitespace { cursor += 1 }
        return cursor
    }

    private static func matches(words: [[Unicode.Scalar]], in scalars: [Unicode.Scalar], at start: Int) -> Bool {
        var cursor = start
        for (wordIndex, word) in words.enumerated() {
            if wordIndex > 0 {
                while cursor < scalars.count,
                    scalars[cursor] == "_" || scalars[cursor] == "-" || scalars[cursor].properties.isWhitespace
                {
                    cursor += 1
                }
            }
            guard cursor + word.count <= scalars.count, scalars[cursor..<(cursor + word.count)].elementsEqual(word) else {
                return false
            }
            cursor += word.count
        }
        return true
    }

    static func attributeValue(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:@+-")
        let cleaned = String(value.prefix(128).map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "_" : cleaned
    }
}
