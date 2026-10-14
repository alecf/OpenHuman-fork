import Foundation
import MailRender

public enum QuoteSplit {
    public static let markerAttribute = "data-oh-quote=\"1\""

    public static func splitHTML(_ html: String) -> (own: String, quote: String) {
        guard let marker = html.range(of: markerAttribute),
              let open = html.range(of: "<div", options: .backwards, range: html.startIndex..<marker.lowerBound) else {
            return (html, "")
        }
        return (String(html[..<open.lowerBound]), String(html[open.lowerBound...]))
    }

    public static func splitText(_ text: String?, quoteHTML: String, ownText: String) -> String {
        guard !quoteHTML.isEmpty else { return "" }
        guard let text else { return Self.text(fromQuoteHTML: quoteHTML) }
        if let line = attributionLine(quoteHTML), let start = text.range(of: line) {
            return String(text[start.lowerBound...])
        }
        let trimmedOwn = ownText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOwn.isEmpty {
            let whole = text.trimmingCharacters(in: .newlines)
            return whole.isEmpty ? Self.text(fromQuoteHTML: quoteHTML) : whole
        }
        if text.hasPrefix(trimmedOwn) {
            let rest = String(text.dropFirst(trimmedOwn.count)).trimmingCharacters(in: .newlines)
            return rest.isEmpty ? Self.text(fromQuoteHTML: quoteHTML) : rest
        }
        return Self.text(fromQuoteHTML: quoteHTML)
    }

    public static func text(fromQuoteHTML quoteHTML: String) -> String {
        let text = PlainTextExtractor.text(fromHTML: quoteHTML, keepQuotes: true)
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard let header = lines.first else { return "" }
        if header.hasPrefix("----------") { return lines.joined(separator: "\n") }
        lines.removeFirst()
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return ([header] + lines.map { $0.isEmpty ? ">" : "> " + $0 }).joined(separator: "\n")
    }

    static func attributionLine(_ quoteHTML: String) -> String? {
        guard let attr = quoteHTML.range(of: "class=\"gmail_attr\""),
              let tagEnd = quoteHTML.range(of: ">", range: attr.upperBound..<quoteHTML.endIndex),
              let close = quoteHTML.range(of: "</div>", range: tagEnd.upperBound..<quoteHTML.endIndex) else { return nil }
        let inner = String(quoteHTML[tagEnd.upperBound..<close.lowerBound])
        let first = inner.components(separatedBy: "<br").first ?? inner
        let text = decodeEntities(first.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    public static func quoteBlockCount(_ html: String) -> Int {
        html.components(separatedBy: markerAttribute).count - 1
    }

    public static func joinText(own: String, quote: String) -> String {
        guard !quote.isEmpty else { return own }
        let trimmed = own.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? "\n\n" + quote : trimmed + "\n\n" + quote
    }
}

public struct QuotePreview: Equatable, Sendable {
    public let header: String
    public let body: String

    public init(header: String, body: String) {
        self.header = header
        self.body = body
    }

    public init(quotedText: String, quotedHTML: String) {
        let text = quotedText.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
        guard !text.isEmpty else {
            self.init(header: QuoteSplit.attributionLine(quotedHTML) ?? "", body: "")
            return
        }
        var lines = text.components(separatedBy: "\n")
        var header: [String] = []
        if lines.first?.hasPrefix(">") == false {
            if lines.first?.hasPrefix("----------") == true {
                while let line = lines.first, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    header.append(line)
                    lines.removeFirst()
                }
            } else {
                header.append(lines.removeFirst())
            }
        }
        let body = lines.map { line -> String in
            if line.hasPrefix("> ") { return String(line.dropFirst(2)) }
            if line.hasPrefix(">") { return String(line.dropFirst()) }
            return line
        }
        self.init(header: header.joined(separator: "\n"),
                  body: body.joined(separator: "\n").trimmingCharacters(in: .newlines))
    }
}
