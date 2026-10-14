import Foundation

public enum HTMLText {
    public static func extract(_ html: String, maxBytes: Int = 64 * 1024) -> String {
        let blocks: Set<String> = ["p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote",
                                   "table", "ul", "ol", "hr", "section", "article", "header", "footer"]
        let skipped: Set<String> = ["script", "style", "head", "title"]
        var out = ""
        let chars = Array(html)
        var i = 0
        var skipUntil: String?
        func lastIsNewline() -> Bool { out.last == "\n" }
        while i < chars.count {
            let c = chars[i]
            if c == "<" {
                if i + 3 < chars.count, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                    var j = i + 4
                    while j + 2 < chars.count, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") { j += 1 }
                    i = min(chars.count, j + 3)
                    continue
                }
                var j = i + 1
                while j < chars.count, chars[j] != ">" { j += 1 }
                let tag = String(chars[(i + 1)..<min(j, chars.count)])
                i = min(chars.count, j + 1)
                let closing = tag.hasPrefix("/")
                let name = tag.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
                if let waiting = skipUntil {
                    if closing && name == waiting { skipUntil = nil }
                    continue
                }
                if !closing && skipped.contains(name) && !tag.hasSuffix("/") { skipUntil = name; continue }
                if blocks.contains(name) && !lastIsNewline() && !out.isEmpty { out.append("\n") }
                continue
            }
            if skipUntil != nil { i += 1; continue }
            if c == "&" {
                var j = i + 1
                while j < chars.count, j - i <= 10, chars[j] != ";", chars[j] != "&", chars[j] != " " { j += 1 }
                if j < chars.count, chars[j] == ";", let decoded = entity(String(chars[(i + 1)..<j])) {
                    out += decoded
                    i = j + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return truncate(collapse(out), maxBytes: maxBytes)
    }

    static func entity(_ body: String) -> String? {
        switch body {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "mdash": return "—"
        case "ndash": return "–"
        case "hellip": return "…"
        case "rsquo": return "’"
        case "lsquo": return "‘"
        case "rdquo": return "”"
        case "ldquo": return "“"
        case "copy": return "©"
        default:
            if body.hasPrefix("#x") || body.hasPrefix("#X"), let v = UInt32(body.dropFirst(2), radix: 16),
               let s = Unicode.Scalar(v) { return String(s) }
            if body.hasPrefix("#"), let v = UInt32(body.dropFirst()), let s = Unicode.Scalar(v) { return String(s) }
            return nil
        }
    }

    static func collapse(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\u{00A0}" })
                .joined(separator: " ")
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func truncate(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var out = ""
        var used = 0
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }
}
