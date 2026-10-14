import Foundation
import SwiftSoup

extension ComposeSerializer {
    public static func importHTML(_ html: String) -> RichTextDocument {
        guard let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body() else {
            return RichTextDocument()
        }
        var importer = HTMLImporter()
        importer.blocks(of: body, depth: 0)
        importer.flush()
        return RichTextDocument(blocks: importer.output).normalized
    }
}

struct HTMLImporter {
    struct Options: Sendable {
        var isPaste = false

        static let draft = Options()
        static let paste = Options(isPaste: true)
    }

    final class Tally {
        var images = 0
        var hidden = 0
    }

    var output: [RichTextDocument.Block] = []
    var inlines: [RichTextDocument.Inline] = []
    var stopped = false
    let options: Options
    let tally: Tally
    var inherited: RichTextDocument.Marks
    static let maxDepth = 64

    init(options: Options = .draft, tally: Tally = Tally(), inherited: RichTextDocument.Marks = []) {
        self.options = options
        self.tally = tally
        self.inherited = inherited
    }

    func nested() -> HTMLImporter {
        HTMLImporter(options: options, tally: tally, inherited: inherited)
    }

    static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "section", "article", "header", "footer", "center",
        "address", "figure", "figcaption", "main", "aside", "nav", "table", "tbody", "thead", "tfoot", "tr", "td", "th",
        "dl", "dt", "dd", "hr",
    ]
    static let skipped: Set<String> = [
        "script", "style", "head", "title", "meta", "link", "template", "svg", "math", "iframe", "object", "embed",
        "noscript", "select", "textarea", "button", "input", "form",
    ]
    static let structureTags: Set<String> = blockTags.union(["ul", "ol", "li", "blockquote"])

    mutating func flush() {
        let content = trimmed(inlines)
        if !content.isEmpty { output.append(.paragraph(content)) }
        inlines = []
    }

    mutating func blocks(of element: Element, depth: Int) {
        for node in element.getChildNodes() {
            if stopped { return }
            if let text = node as? TextNode {
                appendText(text.getWholeText(), marks: inherited)
            } else if let child = node as? Element {
                block(child, depth: depth + 1)
            }
        }
    }

    mutating func block(_ element: Element, depth: Int) {
        let tag = element.tagNameNormal()
        if !options.isPaste {
            if isQuoteMarker(element) { flush(); stopped = true; return }
            if isSignature(element) { return }
        }
        if Self.skipped.contains(tag) { return }
        if options.isPaste, isHidden(element) {
            tally.hidden += 1
            return
        }
        guard depth < Self.maxDepth else {
            appendText((try? element.text()) ?? "", marks: inherited)
            return
        }
        switch tag {
        case "br":
            if !options.isPaste, let next = try? element.nextElementSibling(), isQuoteMarker(next) || isSignature(next) {
                return
            }
            inlines.append(.lineBreak)
        case "ul", "ol":
            flush()
            output.append(.list(ordered: tag == "ol", items: listItems(element, depth: depth)))
        case "blockquote":
            flush()
            var inner = nested()
            inner.blocks(of: element, depth: depth)
            inner.flush()
            output.append(.quote(inner.output))
        case "img":
            if options.isPaste {
                tally.images += 1
            } else if let ref = imageRef(element) {
                flush()
                output.append(.image(ref))
            }
        case "hr":
            flush()
        default:
            let own = ownMarks(tag, element)
            if Self.blockTags.contains(tag) {
                flush()
                let saved = inherited
                inherited = inherited.union(own.add).subtracting(own.remove)
                blocks(of: element, depth: depth)
                flush()
                inherited = saved
            } else if options.isPaste, containsStructure(element, depth: depth) {
                let saved = inherited
                inherited = inherited.union(own.add).subtracting(own.remove)
                blocks(of: element, depth: depth)
                inherited = saved
            } else {
                var run = inlines
                inlineContent(of: element, marks: inherited.union(own.add).subtracting(own.remove), into: &run,
                              depth: depth)
                inlines = run
            }
        }
    }

    mutating func listItems(_ list: Element, depth: Int) -> [[RichTextDocument.Block]] {
        var items: [[RichTextDocument.Block]] = []
        for child in list.children() where child.tagNameNormal() == "li" {
            if options.isPaste, isHidden(child) {
                tally.hidden += 1
                continue
            }
            var inner = nested()
            inner.blocks(of: child, depth: depth + 1)
            inner.flush()
            items.append(inner.output)
        }
        return items
    }

    func inlineContent(of element: Element, marks: RichTextDocument.Marks, into target: inout [RichTextDocument.Inline],
                                depth: Int) {
        guard depth < Self.maxDepth else {
            target.append(.text(collapse((try? element.text()) ?? ""), marks))
            return
        }
        let tag = element.tagNameNormal()
        if tag == "a", let href = try? element.attr("href"), case .allow(let allowed) = URLPolicy.classify(href, context: .link),
           let url = URL(string: allowed) {
            let text = (try? element.text()) ?? ""
            if allowed.lowercased().hasPrefix("mailto:"), text.hasPrefix("@"), element.children().size() == 0 {
                let email = String(allowed.dropFirst(7)).removingPercentEncoding ?? String(allowed.dropFirst(7))
                let name = String(text.dropFirst())
                target.append(.mention(Mention(name: name == email ? nil : name, email: email)))
                return
            }
            var inner: [RichTextDocument.Inline] = []
            for node in element.getChildNodes() { inline(node, marks: marks, into: &inner, depth: depth + 1) }
            target.append(.link(url, inner))
            return
        }
        for node in element.getChildNodes() { inline(node, marks: marks, into: &target, depth: depth + 1) }
    }

    func inline(_ node: Node, marks: RichTextDocument.Marks, into target: inout [RichTextDocument.Inline], depth: Int) {
        if let text = node as? TextNode {
            target.append(.text(collapse(text.getWholeText()), marks))
        } else if let element = node as? Element {
            let tag = element.tagNameNormal()
            if Self.skipped.contains(tag) { return }
            if options.isPaste {
                if isHidden(element) {
                    tally.hidden += 1
                    return
                }
                if tag == "img" {
                    tally.images += 1
                    return
                }
            }
            if tag == "br" { target.append(.lineBreak); return }
            let own = ownMarks(tag, element)
            inlineContent(of: element, marks: marks.union(own.add).subtracting(own.remove), into: &target, depth: depth)
        }
    }

    mutating func appendText(_ raw: String, marks: RichTextDocument.Marks) {
        let text = collapse(raw)
        guard !text.isEmpty else { return }
        inlines.append(.text(text, marks))
    }

    func marks(for tag: String, _ element: Element) -> RichTextDocument.Marks {
        switch tag {
        case "b", "strong": return .bold
        case "i", "em": return .italic
        case "u", "ins": return .underline
        case "s", "strike", "del": return .strikethrough
        case "code", "tt", "kbd", "samp": return .code
        default: return []
        }
    }

    func ownMarks(_ tag: String, _ element: Element) -> (add: RichTextDocument.Marks, remove: RichTextDocument.Marks) {
        let tagMarks = marks(for: tag, element)
        guard options.isPaste else { return (tagMarks, []) }
        let style = styleMarks(element)
        return (tagMarks.union(style.add).subtracting(style.remove), style.remove)
    }

    func styleMarks(_ element: Element) -> (add: RichTextDocument.Marks, remove: RichTextDocument.Marks) {
        guard let style = try? element.attr("style"), !style.isEmpty else { return ([], []) }
        var add: RichTextDocument.Marks = []
        var remove: RichTextDocument.Marks = []
        for declaration in style.lowercased().split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let property = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch property {
            case "font-weight":
                if value == "bold" || value == "bolder" || (Int(value).map { $0 >= 600 } ?? false) {
                    add.insert(.bold)
                } else if value == "normal" || value == "lighter" || (Int(value).map { $0 < 600 } ?? false) {
                    remove.insert(.bold)
                }
            case "font-style":
                if value.hasPrefix("italic") || value.hasPrefix("oblique") {
                    add.insert(.italic)
                } else if value == "normal" {
                    remove.insert(.italic)
                }
            case "text-decoration", "text-decoration-line":
                if value.contains("underline") { add.insert(.underline) }
                if value.contains("line-through") { add.insert(.strikethrough) }
                if value == "none" { remove.formUnion([.underline, .strikethrough]) }
            default:
                break
            }
        }
        return (add, remove)
    }

    func isHidden(_ element: Element) -> Bool {
        if element.hasAttr("hidden") { return true }
        guard let style = try? element.attr("style"), !style.isEmpty else { return false }
        let compact = String(style.lowercased().filter { !$0.isWhitespace })
        return compact.contains("display:none") || compact.contains("visibility:hidden") || compact.contains("mso-hide:all")
    }

    func containsStructure(_ element: Element, depth: Int) -> Bool {
        guard depth < Self.maxDepth else { return false }
        for child in element.children() {
            if Self.structureTags.contains(child.tagNameNormal()) || containsStructure(child, depth: depth + 1) {
                return true
            }
        }
        return false
    }

    func imageRef(_ img: Element) -> RichTextDocument.Block.ImageRef? {
        let src = (try? img.attr("src")) ?? ""
        guard let id = InlineParts.contentID(fromString: src) else { return nil }
        let alt = (try? img.attr("alt")).flatMap { $0.isEmpty ? nil : $0 }
        return InlineImageRef(contentID: id, width: Int((try? img.attr("width")) ?? ""),
                              height: Int((try? img.attr("height")) ?? ""), alt: alt)
    }

    func isSignature(_ element: Element) -> Bool {
        element.hasClass("gmail_signature") || ((try? element.attr("data-smartmail")) == "gmail_signature")
    }

    func isQuoteMarker(_ element: Element) -> Bool {
        element.tagNameNormal() == "div" && element.hasClass("gmail_quote") && ((try? element.attr("data-oh-quote")) == "1")
    }

    func collapse(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var previousSpace = false
        for scalar in s.unicodeScalars {
            if scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" || scalar == "\u{0C}" {
                if !previousSpace { out.append(" ") }
                previousSpace = true
            } else {
                out.append(scalar)
                previousSpace = false
            }
        }
        return String(out)
    }

    func trimmed(_ inlines: [RichTextDocument.Inline]) -> [RichTextDocument.Inline] {
        var items = RichTextDocument.normalize(inlines)
        while case .text(let s, let m)? = items.first {
            let t = s.drop { $0 == " " }
            if t.isEmpty { items.removeFirst() } else { items[0] = .text(String(t), m); break }
        }
        while case .text(let s, let m)? = items.last {
            var t = Substring(s)
            while t.last == " " { t = t.dropLast() }
            if t.isEmpty { items.removeLast() } else { items[items.count - 1] = .text(String(t), m); break }
        }
        return RichTextDocument.normalize(items.map(Self.plainSpaces))
    }

    static func plainSpaces(_ inline: RichTextDocument.Inline) -> RichTextDocument.Inline {
        switch inline {
        case .text(let s, let m): return .text(s.replacingOccurrences(of: "\u{00A0}", with: " "), m)
        case .link(let url, let inner): return .link(url, inner.map(plainSpaces))
        default: return inline
        }
    }
}

extension RichTextDocument.Block {
    typealias ImageRef = InlineImageRef
}
