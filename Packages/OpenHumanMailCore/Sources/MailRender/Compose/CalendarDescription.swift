import Foundation

public enum CalendarDescription {
    public struct Parsed: Sendable, Hashable {
        public let original: String
        public let isHTML: Bool
        public let document: RichTextDocument
        public let editableText: String

        public var isEmpty: Bool { editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public static func parse(_ raw: String?) -> Parsed {
        let original = raw ?? ""
        if looksLikeHTML(original) {
            let document = ComposeSerializer.importHTML(original)
            return Parsed(original: original, isHTML: true, document: document,
                          editableText: ComposeSerializer.plainText(document, signature: nil))
        }
        let text = unescapeICS(original)
        return Parsed(original: original, isHTML: false, document: document(fromPlain: text), editableText: text)
    }

    public static func textToWrite(edited: String, from parsed: Parsed) -> String {
        if edited == parsed.editableText { return parsed.original }
        if parsed.isHTML { return ComposeSerializer.html(document(fromPlain: edited), signature: nil) }
        return edited
    }

    public static func looksLikeHTML(_ text: String) -> Bool {
        text.range(of: #"<\s*/?\s*(a|b|i|u|em|strong|p|br|div|span|ul|ol|li|h[1-6]|table|tr|td|font|html|body|pre|code|blockquote)(\s[^>]*)?/?>"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func unescapeICS(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { out.append(character); continue }
            guard let next = iterator.next() else { out.append(character); break }
            switch next {
            case "n", "N": out.append("\n")
            case ",", ";", "\\": out.append(next)
            default: out.append(character); out.append(next)
            }
        }
        return out
    }

    public static func document(fromPlain text: String) -> RichTextDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
        var blocks: [RichTextDocument.Block] = []
        for paragraph in paragraphs {
            var inlines: [RichTextDocument.Inline] = []
            for (index, line) in paragraph.components(separatedBy: "\n").enumerated() {
                if index > 0 { inlines.append(.lineBreak) }
                inlines += linkified(line)
            }
            if !inlines.isEmpty { blocks.append(.paragraph(inlines)) }
        }
        return RichTextDocument(blocks: blocks).normalized
    }

    static func linkified(_ line: String) -> [RichTextDocument.Inline] {
        var inlines: [RichTextDocument.Inline] = []
        var rest = line[...]
        while let range = rest.range(of: #"https?://[^\s<>"')\]]+"#, options: [.regularExpression, .caseInsensitive]) {
            var address = String(rest[range])
            var trailing = ""
            while let last = address.last, ".,;:!?".contains(last) {
                trailing = String(last) + trailing
                address.removeLast()
            }
            if range.lowerBound > rest.startIndex { inlines.append(.text(String(rest[..<range.lowerBound]), [])) }
            if case .allow(let allowed) = URLPolicy.classify(address, context: .link), let url = URL(string: allowed) {
                inlines.append(.link(url, [.text(address, [])]))
            } else {
                inlines.append(.text(address, []))
            }
            if !trailing.isEmpty { inlines.append(.text(trailing, [])) }
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty { inlines.append(.text(String(rest), [])) }
        return inlines
    }


    public static func attributed(_ document: RichTextDocument) -> AttributedString {
        var out = AttributedString()
        func append(_ blocks: [RichTextDocument.Block], indent: String) {
            for block in blocks {
                if !out.characters.isEmpty { out += AttributedString("\n") }
                switch block {
                case .paragraph(let inlines):
                    out += AttributedString(indent)
                    out += attributed(inlines)
                case .list(let ordered, let items):
                    for (number, item) in items.enumerated() {
                        if number > 0 { out += AttributedString("\n") }
                        out += AttributedString(indent + (ordered ? "\(number + 1). " : "\u{2022} "))
                        var first = true
                        for inner in item {
                            if !first { out += AttributedString("\n") }
                            first = false
                            if case .paragraph(let inlines) = inner { out += attributed(inlines) } else { append([inner], indent: indent + "  ") }
                        }
                    }
                case .quote(let inner):
                    append(inner, indent: indent + "> ")
                case .image:
                    break
                }
            }
        }
        append(document.blocks, indent: "")
        return out
    }

    static func attributed(_ inlines: [RichTextDocument.Inline], link: URL? = nil) -> AttributedString {
        var out = AttributedString()
        for inline in inlines {
            switch inline {
            case .text(let text, let marks):
                var run = AttributedString(text)
                var intent: InlinePresentationIntent = []
                if marks.contains(.bold) { intent.insert(.stronglyEmphasized) }
                if marks.contains(.italic) { intent.insert(.emphasized) }
                if marks.contains(.code) { intent.insert(.code) }
                if marks.contains(.strikethrough) { intent.insert(.strikethrough) }
                if !intent.isEmpty { run.inlinePresentationIntent = intent }
                if let link { run.link = link }
                out += run
            case .link(let url, let inner):
                out += attributed(inner, link: url)
            case .lineBreak:
                out += AttributedString("\n")
            case .mention(let mention):
                out += AttributedString("@" + (mention.name ?? mention.email))
            }
        }
        return out
    }

    public static func openableURL(_ url: URL) -> URL? {
        if case .allow(let allowed) = URLPolicy.classify(url.absoluteString, context: .link) { return URL(string: allowed) }
        return nil
    }
}
