import Foundation
import MailModel

public struct QuoteSelection: Sendable, Hashable {
    public static let maxCharacters = 20_000

    public let message: MessageKey
    public let text: String

    public init?(message: MessageKey, text: String) {
        let trimmed = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.message = message
        self.text = String(trimmed.prefix(Self.maxCharacters))
    }
}

extension ReaderModel {
    public func setQuoteSelection(_ text: String, in message: MessageKey) {
        if let selection = QuoteSelection(message: message, text: text), messages.contains(where: { $0.id == message }) {
            if quoteSelection != selection { quoteSelection = selection }
        } else if quoteSelection?.message == message {
            quoteSelection = nil
        }
    }
}

public enum QuickQuote {
    static let blockquoteOpen = "<blockquote class=\"gmail_quote\" "
        + "style=\"margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex\">"

    public static func quote(_ selection: String, mode: DraftMode, html: String, text: String) -> (html: String, text: String) {
        let lines = selection.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let escaped = lines.map(escape).joined(separator: "<br>")
        let head = header(of: html)
        let quotedHTML: String
        let quotedText: String
        if mode == .forward {
            quotedHTML = head + "<br><br><div>" + escaped + "</div></div>"
            let header = forwardHeader(of: text)
            quotedText = (header.isEmpty ? "" : header + "\n\n") + lines.joined(separator: "\n")
        } else {
            quotedHTML = head + blockquoteOpen + escaped + "</blockquote></div>"
            let attribution = attributionLine(of: text)
            let body = lines.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
            quotedText = attribution.map { $0 + "\n" + body } ?? body
        }
        return (quotedHTML, quotedText)
    }

    static func header(of html: String) -> String {
        let bare = "<div class=\"gmail_quote\" \(QuoteSplit.markerAttribute)>"
        guard let attr = html.range(of: "class=\"gmail_attr\""),
              let tagEnd = html.range(of: ">", range: attr.upperBound..<html.endIndex),
              let close = html.range(of: "</div>", range: tagEnd.upperBound..<html.endIndex),
              html.range(of: QuoteSplit.markerAttribute, range: html.startIndex..<attr.lowerBound) != nil else {
            return bare
        }
        return String(html[..<close.upperBound])
    }

    static func attributionLine(of text: String) -> String? {
        let first = text.trimmingCharacters(in: .newlines).components(separatedBy: "\n").first ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix(">") ? nil : first
    }

    static func forwardHeader(of text: String) -> String {
        var header: [String] = []
        for line in text.trimmingCharacters(in: .newlines).components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            header.append(line)
        }
        return header.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension ComposeManager {
    func openQuotingSelection(_ thread: ThreadKey, mode: DraftMode) -> ComposeSession? {
        if let selection = quoteSelection(in: thread) {
            return openReply(thread, mode: mode, message: selection.message, quoting: selection.text)
        }
        return openReply(thread, mode: mode, message: replyTarget(in: thread))
    }

    func quoteSelection(in thread: ThreadKey) -> QuoteSelection? {
        guard let reader = environment.router.active?.reader, reader.thread == thread,
              let selection = reader.quoteSelection, reader.messages.contains(where: { $0.id == selection.message }) else {
            return nil
        }
        return selection
    }
}
