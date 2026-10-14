import Foundation
import OpenHumanCore

public enum ReplyComposer {
    public static func skeleton(for original: ReplyContext, mode: ReplyMode,
                                myAddresses: [String], locale: Locale, timeZone: TimeZone) -> ReplySkeleton {
        let mine = Set(myAddresses.map { $0.lowercased() })
        func isMe(_ a: EmailAddress) -> Bool { mine.contains(a.email.lowercased()) }

        let fromMe = original.from.map(isMe) ?? false
        let target: [EmailAddress] = fromMe ? original.to
            : (original.replyTo.isEmpty ? (original.from.map { [$0] } ?? []) : original.replyTo)

        let date = formatDate(original.date, locale: locale, timeZone: timeZone)
        let subject = baseSubject(original.subject)

        switch mode {
        case .forward:
            let (html, text) = forwardBlocks(original, date: date)
            return ReplySkeleton(to: [], cc: [], subject: "Fwd: " + subject, inReplyTo: nil, references: [],
                                 quotedHTML: html, quotedText: text, gmailThreadID: nil)
        case .reply, .replyAll:
            let to = dedupe(target)
            var cc: [EmailAddress] = []
            if mode == .replyAll {
                let excluded = Set(to.map { $0.email.lowercased() })
                cc = dedupe((original.to + original.cc).filter { !isMe($0) && !excluded.contains($0.email.lowercased()) })
            }
            let (html, text) = replyBlocks(original, date: date)
            return ReplySkeleton(to: to, cc: cc, subject: "Re: " + subject, inReplyTo: original.messageID,
                                 references: references(original), quotedHTML: html, quotedText: text,
                                 gmailThreadID: original.gmailThreadID)
        }
    }

    public static func makeMessageID(from sender: EmailAddress, uuid: UUID = UUID()) -> String {
        let parts = sender.email.split(separator: "@")
        let domain = parts.count >= 2 ? String(parts[parts.count - 1]) : "localhost"
        let safe = String(domain.unicodeScalars.filter { $0.value > 0x20 && $0.value < 0x7F && $0 != "<" && $0 != ">" })
        return "<oh.\(uuid.uuidString.lowercased())@\(safe.isEmpty ? "localhost" : safe)>"
    }

    static func baseSubject(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes: Set<String> = ["re", "aw", "sv", "fwd", "fw", "wg", "antw", "vs"]
        while true {
            guard let colon = s.firstIndex(of: ":") else { break }
            var head = s[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if let open = head.firstIndex(where: { $0 == "[" || $0 == "(" }) {
                let counter = head[head.index(after: open)...].dropLast()
                guard head.last == "]" || head.last == ")", !counter.isEmpty, counter.allSatisfy(\.isNumber) else { break }
                head = String(head[..<open])
            }
            guard prefixes.contains(head) else { break }
            s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    static func references(_ original: ReplyContext) -> [String] {
        var refs = original.references
        if refs.isEmpty, let irt = original.inReplyTo { refs = [irt] }
        if let id = original.messageID, refs.last != id { refs.append(id) }
        if refs.count > 20 { refs = [refs[0]] + refs.suffix(19) }
        return refs
    }

    private static func dedupe(_ list: [EmailAddress]) -> [EmailAddress] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.email.lowercased()).inserted }
    }

    static func formatDate(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private static func display(_ a: EmailAddress?) -> String {
        guard let a else { return "" }
        if let n = a.name, !n.isEmpty { return "\(n) <\(a.email)>" }
        return a.email
    }

    private static func displayList(_ list: [EmailAddress]) -> String { list.map { display($0) }.joined(separator: ", ") }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func originalHTML(_ o: ReplyContext) -> String {
        if let html = o.htmlBody { return HTMLQuote.clean(html) }
        let text = escape(o.textBody ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>\n")
        return "<div>\(text)</div>"
    }

    private static func originalText(_ o: ReplyContext) -> String {
        let t = o.textBody ?? o.htmlBody.map { HTMLText.extract($0, maxBytes: 1024 * 1024) } ?? ""
        return t.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func replyBlocks(_ o: ReplyContext, date: String) -> (html: String, text: String) {
        let attribution = "On \(date), \(display(o.from)) wrote:"
        let html = "<div class=\"gmail_quote\" data-oh-quote=\"1\"><div class=\"gmail_attr\">\(escape(attribution))<br></div>"
            + "<blockquote class=\"gmail_quote\" style=\"margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex\">"
            + originalHTML(o) + "</blockquote></div>"
        let quoted = originalText(o).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        return (html, attribution + "\n" + quoted)
    }

    private static func forwardBlocks(_ o: ReplyContext, date: String) -> (html: String, text: String) {
        var lines = ["---------- Forwarded message ---------", "From: \(display(o.from))", "Date: \(date)",
                     "Subject: \(o.subject)", "To: \(displayList(o.to))"]
        if !o.cc.isEmpty { lines.append("Cc: \(displayList(o.cc))") }
        let html = "<div class=\"gmail_quote\" data-oh-quote=\"1\"><div class=\"gmail_attr\">"
            + lines.map(escape).joined(separator: "<br>") + "<br></div><br><br>" + originalHTML(o) + "</div>"
        return (html, lines.joined(separator: "\n") + "\n\n" + originalText(o))
    }
}
