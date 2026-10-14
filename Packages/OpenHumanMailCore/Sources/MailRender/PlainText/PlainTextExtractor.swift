import Foundation
import MailModel
import SwiftSoup

public enum PlainTextExtractor {
    public static func extract(_ content: MessageContent, format: PlainTextFormat = .fixed,
                               maxCharacters: Int = 20_000) -> String {
        let text: String
        if let html = content.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = Self.text(fromHTML: html, keepQuotes: false)
        } else if let plain = content.text {
            text = Self.text(fromPlain: plain, format: format)
        } else {
            text = ""
        }
        return limited(text, maxCharacters)
    }

    public static func text(fromHTML html: String, keepQuotes: Bool = false) -> String {
        let sanitized = HTMLSanitizer.Walker.collect(html)
        let boundary: Character = "\u{1}"
        var out = ""
        var hidden = 0
        var pre = 0
        for op in sanitized.ops {
            switch op {
            case .raw(let markup):
                if markup.hasPrefix("<details") { hidden += 1 } else if markup == "</details>" { hidden = max(0, hidden - 1) }
            case .text(let s):
                guard keepQuotes || hidden == 0 else { continue }
                if pre > 0 {
                    out += s
                } else {
                    var collapsed = String.UnicodeScalarView()
                    var lastSpace = false
                    for scalar in s.unicodeScalars {
                        if scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" {
                            if !lastSpace { collapsed.append(" ") }
                            lastSpace = true
                        } else {
                            collapsed.append(scalar)
                            lastSpace = false
                        }
                    }
                    out += String(collapsed)
                }
            case .open(let index):
                let tag = sanitized.elements[index].tag
                if tag == "pre" { pre += 1 }
                guard keepQuotes || hidden == 0 else { continue }
                if tag == "br" { out += "\n" } else if blockTags.contains(tag) { out.append(boundary) }
                if tag == "li" { out += "- " }
            case .close(let tag):
                if tag == "pre" { pre = max(0, pre - 1) }
                if keepQuotes || hidden == 0, blockTags.contains(tag) { out.append(boundary) }
            }
        }
        var result = ""
        var inBoundary = false
        for c in out {
            if c == boundary {
                if !inBoundary { result.append("\n") }
                inBoundary = true
            } else if c == " ", inBoundary {
                continue
            } else {
                result.append(c)
                inBoundary = false
            }
        }
        return tidy(result)
    }

    public static func text(fromPlain plain: String, format: PlainTextFormat = .fixed) -> String {
        let document = PlainTextDocument.parse(plain, format: format)
        var parts: [String] = []
        for (i, block) in document.blocks.enumerated() {
            guard case .body(var text) = block else { continue }
            if let cut = outlookHistoryStart(in: text) { text = String(text[..<cut]) }
            let nextIsQuote: Bool = { if i + 1 < document.blocks.count, case .quote = document.blocks[i + 1] { return true }; return false }()
            if nextIsQuote { text = removingAttribution(text) }
            parts.append(text)
            if outlookHistoryStart(in: block.text) != nil { break }
        }
        return tidy(parts.joined(separator: "\n\n"))
    }

    static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "li", "tr", "table", "blockquote", "section", "article",
        "header", "footer", "dt", "dd", "center", "address", "hr", "ul", "ol", "main", "aside", "nav", "figure",
    ]

    static func removingAttribution(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces).lowercased() else { return text }
        let endings = ["wrote:", "schrieb:", "a écrit :", "a écrit:", "escribió:", "ha scritto:", "schreef:", "skrev:"]
        if endings.contains(where: last.hasSuffix) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func outlookHistoryStart(in text: String) -> String.Index? {
        if let r = text.range(of: "-----Original Message-----") { return r.lowerBound }
        var searchStart = text.startIndex
        while let from = text.range(of: "From:", range: searchStart..<text.endIndex) {
            let atLineStart = from.lowerBound == text.startIndex || text[text.index(before: from.lowerBound)] == "\n"
            let following = text[from.lowerBound...].prefix(600)
            if atLineStart, following.contains("\nSent:") || following.contains("\nDate:"), following.contains("\nSubject:") {
                return from.lowerBound
            }
            searchStart = from.upperBound
        }
        return nil
    }

    static func tidy(_ text: String) -> String {
        var lines: [String] = []
        var blank = 0
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            if line.isEmpty {
                blank += 1
                if blank == 1, !lines.isEmpty { lines.append("") }
            } else {
                blank = 0
                lines.append(line)
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func limited(_ text: String, _ maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let cut = text.prefix(maxCharacters)
        if let space = cut.lastIndex(where: { $0 == " " || $0 == "\n" }), cut.distance(from: cut.startIndex, to: space) > maxCharacters / 2 {
            return String(cut[..<space])
        }
        return String(cut)
    }
}

extension HTMLSanitizer.Walker {
    static func collect(_ html: String) -> HTMLSanitizer.Walker {
        let options = SanitizerOptions()
        let (input, _) = NestingLimiter.truncated(html, maxBytes: options.limits.maxInputBytes)
        let (limited, _) = NestingLimiter.limit(input, maxDepth: options.limits.maxNestingDepth,
                                                maxTableDepth: options.limits.maxTableDepth)
        var walker = HTMLSanitizer.Walker(options: options)
        if let document = try? SwiftSoup.parse(limited), let body = document.body() {
            walker.walk(body)
        }
        return walker
    }
}
