import Foundation
import MailModel
import MailRender
import MailTheme
import OpenHumanCore

public struct PrintedMessage: Sendable {
    public var from: String
    public var to: String
    public var cc: String
    public var date: String
    public var content: MessageContent?

    public init(from: String, to: String, cc: String = "", date: String, content: MessageContent?) {
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.content = content
    }
}

public struct ConversationPrintDocument: Sendable, Equatable {
    public let title: String
    public let html: String

    public init(title: String, html: String) {
        self.title = title
        self.html = html
    }
}

@MainActor
public protocol ConversationPrinting: AnyObject {
    func print(_ document: ConversationPrintDocument)
}

public enum ConversationPrint {
    static let bodyTimeout: Duration = .seconds(15)

    @MainActor
    public static func document(for thread: ThreadKey, data: any MailDataSource,
                                locale: Locale = .current, timeZone: TimeZone = .current) async -> ConversationPrintDocument? {
        var detail: ConversationDetail?
        do {
            for try await value in data.threadDetail(thread) {
                detail = value
                break
            }
        } catch {
            return nil
        }
        guard let detail, !detail.messages.isEmpty else { return nil }
        var printed: [PrintedMessage] = []
        for summary in detail.messages {
            let body = await Self.content(of: summary.id, data: data)
            printed.append(PrintedMessage(from: summary.from.map(Self.display) ?? "",
                                          to: summary.to.map(Self.display).joined(separator: ", "),
                                          cc: summary.cc.map(Self.display).joined(separator: ", "),
                                          date: Self.format(summary.date, locale: locale, timeZone: timeZone),
                                          content: body))
        }
        return ConversationPrintDocument(title: detail.subject, html: Self.html(subject: detail.subject, messages: printed))
    }

    static func content(of key: MessageKey, data: any MailDataSource) async -> MessageContent? {
        await withTaskGroup(of: MessageContent?.self) { group in
            group.addTask {
                do {
                    for try await state in data.body(key) {
                        switch state {
                        case .available(let content): return content
                        case .failed: return nil
                        case .fetching: continue
                        }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: bodyTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    public static func html(subject: String, messages: [PrintedMessage], theme: ThemeTokens = .light) -> String {
        var styles = ""
        var body = "<h1 class=\"oh-print-subject\">" + escape(subject.isEmpty ? "(no subject)" : subject) + "</h1>"
        let colors = ColorContext(theme: theme, appearance: .light, emailColors: theme.readerEmailColors)
        var options = SanitizerOptions()
        options.allowRemoteImages = false
        options.mode = .reader
        for (index, message) in messages.enumerated() {
            let scope = "oh-print-m\(index)"
            body += "<section class=\"oh-print-message\"><div class=\"oh-print-head\">"
            body += line("From", message.from) + line("To", message.to) + line("Cc", message.cc) + line("Date", message.date)
            body += "</div><div class=\"" + scope + "\">"
            if let markup = message.content?.html, !markup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let sanitized = HTMLSanitizer.sanitize(markup, options: options, colors: colors)
                if !sanitized.bodyAttributeCSS.isEmpty { styles += scoped(sanitized.bodyAttributeCSS, under: scope) }
                for css in sanitized.headCSS { styles += scoped(css, under: scope) }
                let classes = (["oh-body"] + (sanitized.bodyClass.isEmpty ? [] : [sanitized.bodyClass])).joined(separator: " ")
                body += "<div class=\"" + escape(classes) + "\"" + sanitized.bodyAttributes + ">"
                    + openFolds(sanitized.bodyHTML) + "</div>"
            } else if let text = message.content?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body += "<div class=\"oh-print-text\">" + escape(text) + "</div>"
            } else {
                body += "<p class=\"oh-print-missing\">This message isn't downloaded, so it isn't printed.</p>"
            }
            body += "</div></section>"
        }
        var page = "<!doctype html><html><head><meta charset=\"utf-8\">"
        page += "<meta http-equiv=\"Content-Security-Policy\" content=\""
            + escape(ReaderDocument.contentSecurityPolicy(allowRemoteImages: false)) + "\">"
        page += "<meta name=\"referrer\" content=\"no-referrer\">"
        page += "<title>" + escape(subject) + "</title>"
        page += "<style id=\"oh-base\">" + ReaderCSS.stylesheet(tokens: theme, colorScheme: .light) + "</style>"
        page += "<style id=\"oh-structure\">" + ReaderDocument.structureCSS(theme: theme) + "</style>"
        page += "<style id=\"oh-print\">" + printCSS + "</style>"
        if !styles.isEmpty { page += "<style>" + styles + "</style>" }
        page += "</head><body><div id=\"oh-root\">" + body + "</div></body></html>"
        return page
    }

    static let printCSS = """
    @page { margin: 16mm; }
    body { background: #ffffff; }
    .oh-print-subject { font-size: 18px; margin: 0 0 12px 0; }
    .oh-print-message { border-top: 1px solid #d0d0d0; padding-top: 10px; margin-top: 14px; }
    .oh-print-head { font-size: 11px; color: #555555; margin-bottom: 8px; break-after: avoid; }
    .oh-print-head b { color: #222222; }
    .oh-print-text { white-space: pre-wrap; }
    .oh-print-missing { color: #777777; font-style: italic; }
    details.oh-quoted > summary { display: none; }
    """

    static func line(_ label: String, _ value: String) -> String {
        value.isEmpty ? "" : "<div><b>" + escape(label) + ":</b> " + escape(value) + "</div>"
    }

    static func scoped(_ css: String, under scope: String) -> String {
        css.replacingOccurrences(of: ".oh-body", with: "." + scope + " .oh-body")
    }

    static func openFolds(_ html: String) -> String {
        html.replacingOccurrences(of: "<details class=\"oh-quoted", with: "<details open class=\"oh-quoted")
    }

    static func display(_ address: EmailAddress) -> String {
        if let name = address.name, !name.isEmpty { return "\(name) <\(address.email)>" }
        return address.email
    }

    static func format(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
        style.timeZone = timeZone
        return date.formatted(style.weekday(.abbreviated))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
