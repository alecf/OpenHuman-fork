import Foundation

enum HTMLQuote {
    static let droppedWithContent: Set<String> = ["script", "style", "head", "iframe", "object", "embed", "noscript", "title"]
    static let droppedTags: Set<String> = ["html", "body", "meta", "link", "base", "!doctype"]

    static func clean(_ html: String) -> String {
        let chars = Array(html.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var skipUntil: String?
        while i < chars.count {
            let c = chars[i]
            guard c == "<" else {
                if skipUntil == nil { out.append(c) }
                i += 1
                continue
            }
            if i + 3 < chars.count, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                var j = i + 4
                while j + 2 < chars.count, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") { j += 1 }
                i = min(chars.count, j + 3)
                continue
            }
            var j = i + 1
            var quote: Unicode.Scalar?
            while j < chars.count {
                let d = chars[j]
                if let q = quote { if d == q { quote = nil } } else if d == "\"" || d == "'" { quote = d } else if d == ">" { break }
                j += 1
            }
            let tagText = String(String.UnicodeScalarView(chars[(i + 1)..<min(j, chars.count)]))
            i = min(chars.count, j + 1)
            let closing = tagText.hasPrefix("/")
            let body = closing ? String(tagText.dropFirst()) : tagText
            let name = String(body.prefix { !($0.isWhitespace || $0 == "/" || $0 == ">") }).lowercased()
            if let waiting = skipUntil {
                if closing && name == waiting { skipUntil = nil }
                continue
            }
            if !closing, droppedWithContent.contains(name), !tagText.hasSuffix("/") { skipUntil = name; continue }
            if droppedWithContent.contains(name) || droppedTags.contains(name) { continue }
            if name.isEmpty { out.append(contentsOf: "&lt;".unicodeScalars); continue }
            if closing { out.append(contentsOf: "</\(name)>".unicodeScalars); continue }
            out.append(contentsOf: rewrite(name: name, rest: String(body.dropFirst(name.count))).unicodeScalars)
        }
        return String(out)
    }

    private static func rewrite(name: String, rest: String) -> String {
        var attrs = parseAttributes(rest)
        attrs.removeAll { $0.name.hasPrefix("on") }
        attrs.removeAll { ["href", "src", "action", "formaction", "xlink:href"].contains($0.name) && isScript($0.value) }
        if name == "img" || name == "input" || name == "video" || name == "audio" || name == "source" {
            attrs.removeAll { ["srcset", "src", "background", "poster"].contains($0.name) && isRemote($0.value) }
        }
        attrs.removeAll { $0.name == "background" && isRemote($0.value) }
        var s = "<" + name
        for a in attrs {
            s += " " + a.name
            if let v = a.value { s += "=\"" + v.replacingOccurrences(of: "\"", with: "&quot;") + "\"" }
        }
        return s + ">"
    }

    private static func isRemote(_ v: String?) -> Bool {
        guard let v = v?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return v.hasPrefix("http:") || v.hasPrefix("https:") || v.hasPrefix("//") || v.hasPrefix("ftp:")
            || v.contains(" http") || v.contains(",http")
    }

    private static func isScript(_ v: String?) -> Bool {
        guard let v else { return false }
        let compact = String(v.lowercased().unicodeScalars.filter { !$0.properties.isWhitespace && $0.value >= 0x20 })
        return compact.hasPrefix("javascript:") || compact.hasPrefix("vbscript:")
    }

    private static func parseAttributes(_ s: String) -> [(name: String, value: String?)] {
        var result: [(String, String?)] = []
        let c = Array(s.unicodeScalars)
        var i = 0
        func skipSpace() { while i < c.count, c[i].properties.isWhitespace || c[i] == "/" { i += 1 } }
        while i < c.count, result.count < 100 {
            skipSpace()
            var name = ""
            while i < c.count, !c[i].properties.isWhitespace, c[i] != "=", c[i] != "/" { name.unicodeScalars.append(c[i]); i += 1 }
            if name.isEmpty { i += 1; continue }
            skipSpace()
            var value: String?
            if i < c.count, c[i] == "=" {
                i += 1
                skipSpace()
                var v = String.UnicodeScalarView()
                if i < c.count, c[i] == "\"" || c[i] == "'" {
                    let q = c[i]
                    i += 1
                    while i < c.count, c[i] != q { v.append(c[i]); i += 1 }
                    i += 1
                } else {
                    while i < c.count, !c[i].properties.isWhitespace { v.append(c[i]); i += 1 }
                }
                value = String(v)
            }
            result.append((name.lowercased(), value))
        }
        return result
    }
}
