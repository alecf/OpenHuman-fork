import Foundation

public enum FlowedText {
    public static let preferredWidth = 78

    public static func encode(_ text: String, width: Int = preferredWidth) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "-- " || line == "--" {
                out.append("-- ")
                continue
            }
            let (depth, content) = composerQuote(String(line))
            var body = content
            while body.last == " " || body.last == "\t" { body.removeLast() }
            let prefix = depth > 0 ? String(repeating: ">", count: depth) + " " : ""
            if body.isEmpty {
                out.append(String(repeating: ">", count: depth))
                continue
            }
            for piece in wrap(body, width: max(width - prefix.count, 20)) {
                let stuffed = depth == 0 && needsStuffing(piece) ? " " + piece : piece
                out.append(prefix + stuffed)
            }
        }
        return out.joined(separator: "\n")
    }

    public static func decode(_ text: String, delSp: Bool) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [(depth: Int, text: String, separator: Bool)] = []
        var continuing = false
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(raw)
            var depth = 0
            while rest.first == ">" { depth += 1; rest = rest.dropFirst() }
            if rest.first == " " { rest = rest.dropFirst() }
            let separator = depth == 0 && rest == "-- "
            let soft = !separator && rest.hasSuffix(" ")
            var content = String(rest)
            if soft, delSp { content.removeLast() }
            if continuing, let last = lines.last, last.depth == depth, !last.separator, !separator {
                lines[lines.count - 1].text += content
            } else {
                lines.append((depth, separator ? "-- " : content, separator))
            }
            continuing = soft
        }
        return lines.map { line in
            line.depth == 0 ? line.text : String(repeating: "> ", count: line.depth) + line.text
        }.joined(separator: "\n")
    }

    static func composerQuote(_ line: String) -> (depth: Int, content: String) {
        var rest = Substring(line)
        var depth = 0
        while rest.first == ">" {
            depth += 1
            rest = rest.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
        }
        return (depth, String(rest))
    }

    static func needsStuffing(_ line: String) -> Bool {
        line.hasPrefix(" ") || line.hasPrefix(">") || line.hasPrefix("From ")
    }

    static func wrap(_ text: String, width: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > width {
            let window = rest.prefix(width)
            var cut: Substring.Index?
            var i = window.startIndex
            while i < window.endIndex {
                let next = rest.index(after: i)
                if rest[i] == " ", next < rest.endIndex, rest[next] != " " { cut = next }
                i = window.index(after: i)
            }
            if cut == nil {
                var j = window.endIndex
                while j < rest.endIndex {
                    let next = rest.index(after: j)
                    if rest[j] == " ", next < rest.endIndex, rest[next] != " " { cut = next; break }
                    j = next
                }
            }
            guard let at = cut, at > rest.startIndex else { break }
            pieces.append(String(rest[..<at]))
            rest = rest[at...]
        }
        pieces.append(String(rest))
        return pieces
    }
}
