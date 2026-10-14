import Foundation
import SwiftSoup

public enum ComposeSerializer {
    public static func html(_ doc: RichTextDocument, signature: SignatureHTML?, style: ComposeStyle = .default) -> String {
        var out = "<div dir=\"auto\"" + styleAttribute(style) + ">"
        for block in doc.blocks { out += html(block) }
        if doc.blocks.isEmpty { out += paragraphOpen + "<br></p>" }
        out += "</div>"
        if let signature {
            let sanitized = HTMLSanitizer.sanitize(signature.html, options: SanitizerOptions(mode: .compose)).bodyHTML
            if !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out += "<br><div class=\"gmail_signature\" data-smartmail=\"gmail_signature\">" + sanitized + "</div>"
            }
        }
        return out
    }

    static let paragraphOpen = "<p style=\"margin:0\">"

    static func styleAttribute(_ style: ComposeStyle) -> String {
        var declarations: [String] = []
        if let family = style.fontFamily, !family.isEmpty,
           family.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == " " || $0 == "-") }) {
            declarations.append("font-family:'\(family)',-apple-system,Helvetica,Arial,sans-serif")
        }
        if let size = style.fontSize, size.isFinite {
            declarations.append("font-size:\(Int(min(max(size, 8), 72).rounded()))px")
        }
        return declarations.isEmpty ? "" : " style=\"" + escapeAttribute(declarations.joined(separator: ";")) + "\""
    }

    static func html(_ block: RichTextDocument.Block) -> String {
        switch block {
        case .paragraph(let inlines):
            let content = html(inlines)
            return paragraphOpen + (content.isEmpty ? "<br>" : content) + "</p>"
        case .list(let ordered, let items):
            let tag = ordered ? "ol" : "ul"
            var out = "<" + tag + ">"
            for item in items {
                out += "<li>"
                if item.count == 1, case .paragraph(let inlines) = item[0] {
                    let content = html(inlines)
                    out += content.isEmpty ? "<br>" : content
                } else {
                    for b in item { out += html(b) }
                }
                out += "</li>"
            }
            return out + "</" + tag + ">"
        case .quote(let blocks):
            return "<blockquote style=\"margin:0 0 0 0.8ex;border-left:1px solid #cccccc;padding-left:1ex\">"
                + blocks.map(html).joined() + "</blockquote>"
        case .image(let ref):
            var out = "<img src=\"" + escapeAttribute(cidURL(ref.contentID)) + "\" alt=\"" + escapeAttribute(ref.alt ?? "") + "\""
            if let w = ref.width, w > 0 { out += " width=\"\(min(w, 10_000))\"" }
            if let h = ref.height, h > 0 { out += " height=\"\(min(h, 10_000))\"" }
            return out + ">"
        }
    }

    static func html(_ inlines: [RichTextDocument.Inline]) -> String {
        let flat = flatText(inlines)
        var keep = Set<Int>()
        let scalars = Array(flat.unicodeScalars)
        for (i, s) in scalars.enumerated() where s == " " {
            if i == 0 || i == scalars.count - 1 || scalars[i - 1] == " " { keep.insert(i) }
        }
        var offset = 0
        return html(inlines, keep: keep, offset: &offset)
    }

    private static func html(_ inlines: [RichTextDocument.Inline], keep: Set<Int>, offset: inout Int) -> String {
        var out = ""
        for inline in inlines {
            switch inline {
            case .text(let s, let marks):
                var text = ""
                for scalar in s.unicodeScalars {
                    switch scalar {
                    case "&": text += "&amp;"
                    case "<": text += "&lt;"
                    case ">": text += "&gt;"
                    case " ": text += keep.contains(offset) ? "&nbsp;" : " "
                    case "\t": text += "&nbsp;&nbsp;&nbsp;&nbsp;"
                    case "\n": text += "<br>"
                    case "\u{0}": break
                    default: text.unicodeScalars.append(scalar)
                    }
                    offset += 1
                }
                out += wrap(text, marks)
            case .link(let url, let inner):
                let content = html(inner, keep: keep, offset: &offset)
                if let href = linkHref(url) {
                    out += "<a href=\"" + escapeAttribute(href) + "\">" + content + "</a>"
                } else {
                    out += content
                }
            case .lineBreak:
                out += "<br>"
            case .mention(let mention):
                let label = mention.label
                offset += label.unicodeScalars.count
                out += "<a href=\"" + escapeAttribute("mailto:" + mention.email) + "\">" + escapeText(label) + "</a>"
            }
        }
        return out
    }

    static func flatText(_ inlines: [RichTextDocument.Inline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s, _): return s
            case .link(_, let inner): return flatText(inner)
            case .lineBreak: return ""
            case .mention(let m): return m.label
            }
        }.joined()
    }

    static func wrap(_ text: String, _ marks: RichTextDocument.Marks) -> String {
        var out = text
        if marks.contains(.code) { out = "<code>" + out + "</code>" }
        if marks.contains(.strikethrough) { out = "<s>" + out + "</s>" }
        if marks.contains(.underline) { out = "<u>" + out + "</u>" }
        if marks.contains(.italic) { out = "<em>" + out + "</em>" }
        if marks.contains(.bold) { out = "<strong>" + out + "</strong>" }
        return out
    }

    static func linkHref(_ url: URL) -> String? {
        guard case .allow(let href) = URLPolicy.classify(url.absoluteString, context: .link) else { return nil }
        return href
    }

    static func cidURL(_ contentID: String) -> String {
        "cid:" + String(InlineParts.urlString(forContentID: contentID).dropFirst(URLPolicy.inlinePartScheme.count + 1))
    }

    public static func plainText(_ doc: RichTextDocument, signature: SignatureHTML?) -> String {
        var lines: [String] = []
        for block in doc.blocks { lines += text(block, indent: "") }
        var out = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n")
        if let signature {
            let sig = (signature.text ?? PlainTextExtractor.text(fromHTML: signature.html, keepQuotes: true))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sig.isEmpty { out += (out.isEmpty ? "" : "\n\n") + "-- \n" + sig }
        }
        return out
    }

    static func text(_ block: RichTextDocument.Block, indent: String) -> [String] {
        switch block {
        case .paragraph(let inlines):
            return text(inlines).components(separatedBy: "\n").map { indent + $0 }
        case .list(let ordered, let items):
            var lines: [String] = []
            for (n, item) in items.enumerated() {
                let marker = ordered ? "\(n + 1). " : "- "
                let continuation = indent + String(repeating: " ", count: marker.count)
                var first = true
                for b in item {
                    for line in text(b, indent: "") {
                        if first { lines.append(indent + marker + line); first = false } else { lines.append(continuation + line) }
                    }
                }
                if first { lines.append(indent + marker.trimmingCharacters(in: .whitespaces)) }
            }
            return lines
        case .quote(let blocks):
            return blocks.flatMap { text($0, indent: "") }.map { indent + "> " + $0 }
        case .image(let ref):
            return [indent + "[" + ((ref.alt?.isEmpty == false ? ref.alt : nil).map { "image: " + $0 } ?? "image") + "]"]
        }
    }

    static func text(_ inlines: [RichTextDocument.Inline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s, _):
                return s
            case .link(let url, let inner):
                let label = text(inner)
                let target = url.absoluteString.hasPrefix("mailto:") ? String(url.absoluteString.dropFirst(7)) : url.absoluteString
                return label == target || label == url.absoluteString || label.isEmpty ? target : label + " (" + target + ")"
            case .lineBreak:
                return "\n"
            case .mention(let m):
                return m.label
            }
        }.joined()
    }
}
