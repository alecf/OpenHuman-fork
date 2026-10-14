import Foundation
import MailTheme
import SwiftSoup

public struct SanitizerOptions: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        case reader
        case compose
    }

    public var allowRemoteImages: Bool
    public var trackerHosts: Set<String>
    public var limits: RenderLimits
    public var mode: Mode
    public var trimBlankSpace: Bool

    public init(allowRemoteImages: Bool = false, trackerHosts: Set<String> = TrackerList.hosts,
                limits: RenderLimits = .default, mode: Mode = .reader, trimBlankSpace: Bool = true) {
        self.trimBlankSpace = trimBlankSpace
        self.allowRemoteImages = allowRemoteImages
        self.trackerHosts = trackerHosts
        self.limits = limits
        self.mode = mode
    }
}

public struct ColorContext: Sendable, Hashable {
    public var appearance: ThemeAppearance
    public var emailColors: EmailColors
    public var override: ColorOverride?
    public var canvas: ThemeColor
    public var text: ThemeColor
    public var link: ThemeColor

    public init(appearance: ThemeAppearance, emailColors: EmailColors, override: ColorOverride? = nil,
                canvas: ThemeColor, text: ThemeColor, link: ThemeColor) {
        self.appearance = appearance
        self.emailColors = emailColors
        self.override = override
        self.canvas = canvas
        self.text = text
        self.link = link
    }

    public init(theme: ThemeTokens, appearance: ThemeAppearance, emailColors: EmailColors, override: ColorOverride? = nil) {
        self.init(appearance: appearance, emailColors: emailColors, override: override, canvas: theme.bgCard,
                  text: theme.textPrimary, link: theme.accentText)
    }
}

public struct SanitizedHTML: Sendable, Equatable {
    public var headCSS: [String]
    public var bodyHTML: String
    public var bodyAttributes: String
    public var bodyClass: String
    public var bodyAttributeCSS: String
    public var remoteReferences: Int
    public var trackerReferences: Int
    public var blockedRemote: Int
    public var trackers: Int
    public var trackerDomains: [String]
    public var hasQuotedText: Bool
    public var tier: DarkModeTier
    public var treatment: ColorTreatment
    public var suspiciousLinks: [SuspiciousLink]
    public var inlineContentIDs: [String]
    public var textLength: Int
    public var isTruncated: Bool
    public var nestingLimited: Bool
}

public enum HTMLSanitizer {
    public static let version = 4

    static let allowedTags: Set<String> = [
        "a", "abbr", "acronym", "address", "article", "aside", "b", "bdi", "bdo", "big", "blockquote", "br",
        "caption", "center", "cite", "code", "col", "colgroup", "dd", "del", "details", "dfn", "div", "dl", "dt",
        "em", "figcaption", "figure", "font", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "i",
        "img", "ins", "kbd", "li", "main", "mark", "nav", "ol", "p", "pre", "q", "rp", "rt", "ruby", "s", "samp",
        "section", "small", "span", "strike", "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot",
        "th", "thead", "time", "tr", "tt", "u", "ul", "var", "wbr",
    ]
    static let droppedWithContent: Set<String> = [
        "script", "style", "iframe", "frame", "frameset", "object", "embed", "applet", "param", "form", "input",
        "button", "select", "option", "optgroup", "datalist", "textarea", "base", "link", "meta", "title", "svg",
        "math", "template", "noembed", "noframes", "xmp", "plaintext", "portal", "canvas", "dialog", "slot", "map",
        "area", "source", "track", "keygen", "isindex", "head", "fencedframe", "search", "menu", "output",
        "selectedcontent", "frameset", "image", "listing",
    ]
    static let mediaTags: Set<String> = ["video", "audio", "picture"]
    static let voidTags: Set<String> = ["br", "col", "hr", "img", "wbr"]
    static let globalAttributes: Set<String> = [
        "style", "class", "id", "dir", "lang", "title", "align", "valign", "width", "height", "bgcolor", "role",
        "aria-label", "aria-hidden",
    ]
    static let tagAttributes: [String: Set<String>] = [
        "a": ["href", "name"],
        "img": ["src", "alt", "border", "hspace", "vspace"],
        "table": ["border", "cellpadding", "cellspacing", "background", "summary", "frame", "rules"],
        "td": ["colspan", "rowspan", "nowrap", "background", "scope", "headers", "abbr", "axis"],
        "th": ["colspan", "rowspan", "nowrap", "background", "scope", "headers", "abbr", "axis"],
        "tr": ["background"],
        "col": ["span"], "colgroup": ["span"],
        "ol": ["start", "type", "reversed"], "ul": ["type"], "li": ["value", "type"],
        "font": ["color", "face", "size"],
        "blockquote": ["type"],
        "details": ["open"],
        "time": ["datetime"], "del": ["datetime"], "ins": ["datetime"],
        "br": ["clear"], "hr": ["noshade", "size"],
    ]
    static let booleanAttributes: Set<String> = ["nowrap", "open", "reversed", "noshade"]
    static let numericAttributes: Set<String> = [
        "width", "height", "border", "cellpadding", "cellspacing", "hspace", "vspace", "colspan", "rowspan", "span",
        "start", "value", "size",
    ]
    static let foldableParents: Set<String> = [
        "div", "td", "th", "blockquote", "section", "article", "main", "li", "center", "dd", "aside", "header",
        "footer", "nav", "figure", "details",
    ]

    public static func sanitize(_ html: String, options: SanitizerOptions = SanitizerOptions(),
                                colors: ColorContext? = nil) -> SanitizedHTML {
        let (input, truncated) = NestingLimiter.truncated(html, maxBytes: options.limits.maxInputBytes)
        let (limited, nestingLimited) = NestingLimiter.limit(input, maxDepth: options.limits.maxNestingDepth,
                                                             maxTableDepth: options.limits.maxTableDepth)
        var walker = Walker(options: options)
        do {
            let document = try SwiftSoup.parse(limited)
            if let head = document.head() { walker.collectHead(head) }
            if let body = document.body() {
                walker.collectBody(body)
                walker.walk(body)
            }
        } catch {
            walker = Walker(options: options)
        }
        if truncated { walker.truncated = true }
        let tier = walker.classifier.tier
        let treatment: ColorTreatment
        let transform: ColorTransform
        if let colors {
            treatment = DarkModePolicy.treatment(tier: tier, appearance: colors.appearance,
                                                 emailColors: colors.emailColors, override: colors.override)
            transform = ColorTransform(treatment: treatment)
        } else {
            treatment = .original
            transform = ColorTransform.identity
        }
        var writer = Writer(walker: walker, transform: transform, colors: treatment == .remapped ? colors : nil)
        let body = writer.write()
        return SanitizedHTML(
            headCSS: walker.stylesheets.map { CSSSerializer.serialize(CSSWriter.tokens(transform.apply($0))) }
                .filter { !$0.isEmpty },
            bodyHTML: body, bodyAttributes: writer.bodyAttributes, bodyClass: writer.bodyClass,
            bodyAttributeCSS: writer.bodyAttributeCSS,
            remoteReferences: walker.remote, trackerReferences: walker.remoteTrackers, blockedRemote: walker.blocked,
            trackers: walker.trackers, trackerDomains: walker.trackerDomains.sorted(), hasQuotedText: walker.quoted,
            tier: tier, treatment: treatment, suspiciousLinks: walker.links, inlineContentIDs: walker.inlineIDs,
            textLength: walker.textLength, isTruncated: walker.truncated, nestingLimited: nestingLimited)
    }

    struct Attributes {
        var pairs: [(key: String, value: String)] = []

        init(_ element: Element) {
            for a in element.getAttributes()?.asList() ?? [] { pairs.append((a.getKey().lowercased(), a.getValue())) }
        }

        subscript(_ key: String) -> String {
            for p in pairs where p.key == key { return p.value }
            return ""
        }

        var isEmpty: Bool { pairs.isEmpty }
    }

    static let allowedAttributes: [String: Set<String>] = {
        var table: [String: Set<String>] = [:]
        for tag in allowedTags { table[tag] = globalAttributes.union(tagAttributes[tag] ?? []) }
        return table
    }()

    struct ImageSource {
        let decision: URLPolicy.Decision
        let isTracker: Bool
    }

    enum AttributeOp {
        case plain(String, String)
        case style
        case color(String, String)
    }

    struct OpenElement {
        var tag: String
        var attributes: [AttributeOp]
        var style: [CSSDeclaration]
        var hasDirectText = false
        var isLink = false
    }

    enum Op {
        case open(Int)
        case close(String)
        case text(String)
        case raw(String)
    }

    struct Frame {
        let children: [Node]
        var index = 0
        let closeTag: String?
        var insideQuote: Bool
        var foldOpen = false
        let wrappedInDetails: Bool
        let depth: Int
        let element: Int?
        let parentTag: String?
    }

    struct Walker {
        let options: SanitizerOptions
        var ops: [Op] = []
        var elements: [OpenElement] = []
        var stylesheets: [[CSSItem]] = []
        var stylesheetBytes = 0
        var body: [CSSDeclaration] = []
        var bodyAttributes: [AttributeOp] = []
        var bodyBackground: String?
        var classifier = DarkModeClassifier()
        var remote = 0
        var remoteTrackers = 0
        var blocked = 0
        var trackers = 0
        var trackerDomains = Set<String>()
        var quoted = false
        var links: [SuspiciousLink] = []
        var inlineIDs: [String] = []
        var textLength = 0
        var truncated = false
        var emittedElements = 0
        static let maxDepth = 512
        var seenVisible = false
        var lastBlank = false
        var brRun = 0
        var keptBlanks = Set<Int>()
        var cleanup: Bool { options.mode == .reader && options.trimBlankSpace }

        init(options: SanitizerOptions) {
            self.options = options
        }

        mutating func collectHead(_ head: Element) {
            for child in head.children() {
                switch child.tagNameNormal() {
                case "style": collectStylesheet(child)
                case "meta": noteMeta(child)
                default: continue
                }
            }
        }

        mutating func noteMeta(_ meta: Element) {
            let attrs = Attributes(meta)
            classifier.noteMeta(name: attrs["name"], content: attrs["content"])
        }

        mutating func collectStylesheet(_ style: Element) {
            guard options.mode == .reader else { return }
            var css = ""
            for node in style.getChildNodes() {
                if let data = node as? DataNode { css += data.getWholeData() } else if let text = node as? TextNode { css += text.getWholeText() }
            }
            guard stylesheetBytes + css.utf8.count <= options.limits.maxStylesheetBytes else { return }
            stylesheetBytes += css.utf8.count
            var sanitizer = cssSanitizer(scoped: true)
            let items = sanitizer.stylesheet(css)
            merge(sanitizer.stats)
            if sanitizer.stats.hasDarkMediaQuery { classifier.noteDarkMediaQuery() }
            classifier.note(items)
            if !items.isEmpty { stylesheets.append(items) }
        }

        func cssSanitizer(scoped: Bool) -> CSSSanitizer {
            var s = CSSSanitizer(allowRemoteImages: options.allowRemoteImages || options.mode == .compose,
                                 scopeSelectors: scoped, trackerHosts: options.trackerHosts)
            s.composeURLs = options.mode == .compose
            return s
        }

        mutating func merge(_ stats: CSSSanitizeStats) {
            remote += stats.remoteReferences
            remoteTrackers += stats.trackers
            trackers += stats.trackers
            blocked += stats.blockedRemote - stats.trackers
            for id in stats.inlineContentIDs where !inlineIDs.contains(id) { inlineIDs.append(id) }
            for host in stats.trackerHosts { if let domain = RegistrableDomain.of(host) { trackerDomains.insert(domain) } }
        }

        mutating func collectBody(_ body: Element) {
            guard options.mode == .reader else { return }
            for attribute in body.getAttributes()?.asList() ?? [] {
                let key = attribute.getKey().lowercased()
                let value = attribute.getValue()
                guard value.utf8.count <= options.limits.maxStyleAttributeLength else { continue }
                switch key {
                case "style":
                    var sanitizer = cssSanitizer(scoped: false)
                    let declarations = sanitizer.declarations(value)
                    merge(sanitizer.stats)
                    classifier.note(declarations)
                    self.body += declarations
                case "bgcolor", "text":
                    classifier.noteAttribute(key, value: value)
                    bodyAttributes.append(.color(key, value))
                case "background":
                    classifier.noteAttribute(key, value: value)
                    if let url = imageURL(value, known: nil) { bodyBackground = url }
                case "dir":
                    if ["ltr", "rtl", "auto"].contains(value.lowercased()) { bodyAttributes.append(.plain("dir", value.lowercased())) }
                case "lang":
                    bodyAttributes.append(.plain("lang", value))
                case "class":
                    if let classes = filteredClasses(value) { bodyAttributes.append(.plain("class", classes)) }
                default:
                    continue
                }
            }
        }

        mutating func walk(_ body: Element) {
            var stack = [Frame(children: body.getChildNodes(), closeTag: nil, insideQuote: false, wrappedInDetails: false,
                               depth: 0, element: nil, parentTag: "body")]
            while !stack.isEmpty {
                let top = stack.count - 1
                if stack[top].index >= stack[top].children.count || truncated {
                    let frame = stack.removeLast()
                    if frame.foldOpen { ops.append(.raw("</details>")) }
                    if let tag = frame.closeTag { ops.append(.close(tag)) }
                    if frame.wrappedInDetails { ops.append(.raw("</details>")) }
                    continue
                }
                let node = stack[top].children[stack[top].index]
                stack[top].index += 1
                if let text = node as? TextNode {
                    emitText(text.getWholeText(), into: stack[top].element)
                } else if let element = node as? Element {
                    visit(element, stack: &stack)
                }
            }
        }

        mutating func emitText(_ text: String, into element: Int?) {
            guard !text.isEmpty else { return }
            if cleanup {
                if Self.hasVisibleCharacter(text) {
                    seenVisible = true
                    lastBlank = false
                    brRun = 0
                } else if !seenVisible, element == nil, !text.unicodeScalars.allSatisfy({ $0.value < 128 }) {
                    return
                }
            }
            ops.append(.text(text))
            if let element, !elements[element].hasDirectText, text.utf8.contains(where: { $0 > 32 }) {
                elements[element].hasDirectText = true
            }
            textLength += text.utf16.count
        }

        mutating func visit(_ element: Element, stack: inout [Frame]) {
            let top = stack.count - 1
            let frame = stack[top]
            let tag = element.tagNameNormal()
            if tag == "style" { collectStylesheet(element); return }
            if tag == "meta" { noteMeta(element); return }
            if HTMLSanitizer.droppedWithContent.contains(tag) { return }
            if HTMLSanitizer.mediaTags.contains(tag) {
                if tag == "picture" {
                    stack.append(Frame(children: element.getChildNodes(), closeTag: nil, insideQuote: frame.insideQuote,
                                       wrappedInDetails: false, depth: frame.depth + 1, element: frame.element,
                                       parentTag: frame.parentTag))
                } else {
                    ops.append(.raw("<span class=\"oh-placeholder\">(media not shown)</span>"))
                }
                return
            }
            guard frame.depth < Self.maxDepth else {
                emitText((try? element.text()) ?? "", into: frame.element)
                return
            }
            let attrs = Attributes(element)
            if cleanup, tag != "img", Self.isHidden(attrs) {
                noteDroppedHidden(element, attrs: attrs)
                return
            }
            guard HTMLSanitizer.allowedTags.contains(tag) else {
                stack.append(Frame(children: element.getChildNodes(), closeTag: nil, insideQuote: frame.insideQuote,
                                   wrappedInDetails: false, depth: frame.depth + 1, element: frame.element,
                                   parentTag: frame.parentTag))
                return
            }
            var source: ImageSource?
            if tag == "img" {
                let decision = URLPolicy.classify(attrs["src"], context: options.mode == .compose ? .composeImage : .image)
                var isTracker = false
                if case .remote(let url) = decision { isTracker = TrackerList.isTracker(url: url, in: options.trackerHosts) }
                source = ImageSource(decision: decision, isTracker: isTracker)
                if isTracker || isTrackingPixel(attrs) {
                    trackers += 1
                    if case .remote(let url) = decision {
                        remote += 1
                        remoteTrackers += 1
                        noteTrackerDomain(url)
                    }
                    return
                }
            }
            emittedElements += 1
            if emittedElements > options.limits.maxElements { truncated = true; return }
            if cleanup {
                let wasBlank = lastBlank
                if trimmedAsBlank(element, tag: tag, attrs: attrs, stack: stack) { return }
                if lastBlank, !wasBlank { keptBlanks.insert(elements.count) }
            }

            var insideQuote = frame.insideQuote
            if options.mode == .reader, !insideQuote, isRestFoldMarker(element, tag: tag, attrs: attrs),
               frame.parentTag.map({ $0 == "body" || HTMLSanitizer.foldableParents.contains($0) }) ?? true {
                quoted = true
                ops.append(.raw(Self.detailsOpen(signature: false)))
                stack[top].foldOpen = true
                stack[top].insideQuote = true
                insideQuote = true
            }
            var wrap = false
            if options.mode == .reader, !insideQuote {
                if isQuotedHistory(tag: tag, attrs: attrs), !isForwarded(element, tag: tag) {
                    wrap = true
                    ops.append(.raw(Self.detailsOpen(signature: false)))
                } else if isSignature(tag: tag, attrs: attrs) {
                    wrap = true
                    ops.append(.raw(Self.detailsOpen(signature: true)))
                }
                if wrap { quoted = true }
            }
            let index = elements.count
            elements.append(open(element, tag: tag, attrs: attrs, source: source))
            ops.append(.open(index))
            if HTMLSanitizer.voidTags.contains(tag) {
                if wrap { ops.append(.raw("</details>")) }
                return
            }
            stack.append(Frame(children: element.getChildNodes(), closeTag: tag, insideQuote: insideQuote || wrap,
                               wrappedInDetails: wrap, depth: frame.depth + 1, element: index, parentTag: tag))
        }

        static let blankBlockTags: Set<String> = [
            "p", "div", "tr", "table", "center", "section", "article", "header", "footer",
        ]
        static let contentTags: Set<String> = [
            "img", "hr", "picture", "video", "audio", "li", "details", "iframe", "object", "embed", "canvas", "svg",
        ]
        static let spacerRow = "<tr><td height=\"16\"></td></tr>"

        mutating func noteDroppedHidden(_ element: Element, attrs: Attributes) {
            let style = attrs["style"]
            if !style.isEmpty, style.utf8.count <= options.limits.maxStyleAttributeLength {
                var sanitizer = cssSanitizer(scoped: false)
                let declarations = sanitizer.declarations(style)
                merge(sanitizer.stats)
                classifier.note(declarations)
            }
            guard let images = try? element.getElementsByTag("img") else { return }
            for image in images {
                let imgAttrs = Attributes(image)
                let decision = URLPolicy.classify(imgAttrs["src"], context: .image)
                var isTracker = false
                if case .remote(let url) = decision { isTracker = TrackerList.isTracker(url: url, in: options.trackerHosts) }
                guard isTracker || isTrackingPixel(imgAttrs) else { continue }
                trackers += 1
                if case .remote(let url) = decision {
                    remote += 1
                    remoteTrackers += 1
                    noteTrackerDomain(url)
                }
            }
        }

        mutating func trimmedAsBlank(_ element: Element, tag: String, attrs: Attributes, stack: [Frame]) -> Bool {
            if !keptBlanks.isEmpty, stack.contains(where: { $0.element.map(keptBlanks.contains) ?? false }) { return false }
            if tag == "br" {
                if !seenVisible { return true }
                brRun += 1
                return brRun > 2
            }
            if tag == "img" || tag == "hr" {
                seenVisible = true
                lastBlank = false
                brRun = 0
                return false
            }
            brRun = 0
            guard Self.blankBlockTags.contains(tag), Self.isBlank(element) else {
                lastBlank = false
                return false
            }
            if !seenVisible || lastBlank { return true }
            lastBlank = true
            switch tag {
            case "tr":
                ops.append(.raw(Self.spacerRow))
                return true
            case "p", "div":
                guard Self.isSizedSpacer(attrs) else { return false }
                ops.append(.raw("<\(tag)>&nbsp;</\(tag)>"))
                return true
            default:
                return true
            }
        }

        static func isSizedSpacer(_ attrs: Attributes) -> Bool {
            if !attrs["height"].isEmpty { return true }
            let style = styleMap(attrs["style"])
            return style["height"] != nil || style["min-height"] != nil || style["line-height"] != nil
                || style["padding-top"] != nil || style["padding-bottom"] != nil || style["padding"] != nil
                || style["margin-top"] != nil || style["margin-bottom"] != nil
        }

        static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
            if scalar.properties.isWhitespace { return true }
            switch scalar.value {
            case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180E, 0x200B...0x200F,
                 0x202A...0x202E, 0x2060...0x206F, 0x3164, 0xFE00...0xFE0F, 0xFEFF, 0xFFA0:
                return true
            default:
                return false
            }
        }

        static func hasVisibleCharacter(_ text: String) -> Bool {
            text.unicodeScalars.contains { !isInvisible($0) }
        }

        static func isBlank(_ element: Element) -> Bool {
            var stack: [Node] = [element]
            var visited = 0
            while let node = stack.popLast() {
                visited += 1
                if visited > 2000 { return false }
                if let text = node as? TextNode {
                    if hasVisibleCharacter(text.getWholeText()) { return false }
                } else if let el = node as? Element {
                    if contentTags.contains(el.tagNameNormal()) { return false }
                    for (key, value) in Attributes(el).pairs {
                        switch key {
                        case "bgcolor", "background", "id": return false
                        case "border" where value != "0" && !value.isEmpty: return false
                        case "style":
                            let lower = value.lowercased()
                            if lower.contains("background") || lower.contains("border") { return false }
                        default: break
                        }
                    }
                    stack.append(contentsOf: el.getChildNodes())
                }
            }
            return true
        }

        static func styleMap(_ raw: String) -> [String: String] {
            var result: [String: String] = [:]
            let cleaned = raw.lowercased().replacingOccurrences(of: "!important", with: "")
            for part in cleaned.split(separator: ";") {
                guard let colon = part.firstIndex(of: ":") else { continue }
                let key = part[..<colon].trimmingCharacters(in: .whitespaces)
                let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                result[key] = value
            }
            return result
        }

        static func isZero(_ value: String?) -> Bool {
            guard var value else { return false }
            while let last = value.last, last.isLetter || last == "%" { value.removeLast() }
            return Double(value.trimmingCharacters(in: .whitespaces)) == 0
        }

        // Why: `mso-hide:all` alone hides in Outlook only, so it counts only next to another hiding declaration
        static func isHidden(_ attrs: Attributes) -> Bool {
            if attrs.pairs.contains(where: { $0.key == "hidden" }) { return true }
            let raw = attrs["style"]
            guard !raw.isEmpty, attrs["class"].isEmpty, attrs["id"].isEmpty else { return false }
            let s = styleMap(raw)
            let overflowHidden = ["overflow", "overflow-x", "overflow-y"].contains { s[$0] == "hidden" || s[$0] == "clip" }
            let displayNone = s["display"] == "none"
            if displayNone || s["visibility"] == "hidden" || s["visibility"] == "collapse" { return true }
            if overflowHidden, isZero(s["max-height"]) || isZero(s["height"]) { return true }
            if isZero(s["opacity"]), isZero(s["font-size"]) { return true }
            if s["mso-hide"] == "all",
               displayNone || overflowHidden || isZero(s["max-height"]) || isZero(s["height"]) || isZero(s["font-size"])
                || isZero(s["opacity"]) {
                return true
            }
            return false
        }

        static func detailsOpen(signature: Bool) -> String {
            signature
                ? "<details class=\"oh-quoted oh-signature\"><summary title=\"Show signature\">\u{2022}\u{2022}\u{2022}</summary>"
                : "<details class=\"oh-quoted\"><summary title=\"Show quoted text\">\u{2022}\u{2022}\u{2022}</summary>"
        }

        mutating func open(_ element: Element, tag: String, attrs: Attributes, source: ImageSource?) -> OpenElement {
            var result = OpenElement(tag: tag, attributes: [], style: [])
            let allowed = HTMLSanitizer.allowedAttributes[tag] ?? HTMLSanitizer.globalAttributes
            let limits = options.limits
            var hasHref = false
            for (key, value) in attrs.pairs {
                guard allowed.contains(key) else { continue }
                let isDataImage = (key == "src" || key == "background") && value.prefix(5).lowercased() == "data:"
                let maxLength = key == "style" ? limits.maxStyleAttributeLength
                    : isDataImage ? limits.maxDataURLLength : limits.maxAttributeLength
                guard value.utf8.count <= maxLength else { continue }
                switch key {
                case "style":
                    var sanitizer = cssSanitizer(scoped: false)
                    let declarations = sanitizer.declarations(value)
                    merge(sanitizer.stats)
                    classifier.note(declarations, link: tag == "a")
                    if !declarations.isEmpty {
                        result.style += declarations
                        result.attributes.append(.style)
                    }
                case "href":
                    guard case .allow(let url) = URLPolicy.classify(value, context: .link) else { continue }
                    result.attributes.append(.plain("href", url))
                    hasHref = true
                    if options.mode == .reader,
                       let warning = LinkAnalyzer.check(href: url, displayText: String(((try? element.text()) ?? "").prefix(2048))) {
                        links.append(warning)
                    }
                case "src", "background":
                    let known = key == "src" ? source : nil
                    if let url = imageURL(value, known: known) {
                        result.attributes.append(.plain(key, url))
                    } else if key == "src", tag == "img", options.mode == .reader, case .remote? = known?.decision {
                        result.attributes.append(.plain("class", "oh-blocked"))
                    }
                    if key == "background" { classifier.noteAttribute("background", value: value) }
                case "bgcolor", "color":
                    classifier.noteAttribute(key, value: value)
                    result.attributes.append(.color(key, value))
                case "id":
                    if !value.lowercased().hasPrefix("oh-") { result.attributes.append(.plain("id", value)) }
                case "class":
                    if let classes = filteredClasses(value) { result.attributes.append(.plain("class", classes)) }
                case "dir":
                    if ["ltr", "rtl", "auto"].contains(value.lowercased()) { result.attributes.append(.plain("dir", value.lowercased())) }
                default:
                    if HTMLSanitizer.booleanAttributes.contains(key) {
                        result.attributes.append(.plain(key, ""))
                    } else if HTMLSanitizer.numericAttributes.contains(key) {
                        result.attributes.append(.plain(key, Self.clampedNumeric(value)))
                    } else {
                        result.attributes.append(.plain(key, value))
                    }
                }
            }
            if tag == "a", hasHref {
                result.attributes.append(.plain("rel", "noopener noreferrer"))
                result.isLink = true
            }
            let classes = result.attributes.compactMap { op -> String? in if case .plain("class", let v) = op { return v }; return nil }
            if classes.count > 1 {
                result.attributes.removeAll { if case .plain("class", _) = $0 { return true }; return false }
                result.attributes.append(.plain("class", classes.joined(separator: " ")))
            }
            return result
        }

        mutating func noteTrackerDomain(_ url: String) {
            if let host = URLPolicy.httpParts(url)?.host, let domain = RegistrableDomain.of(host) { trackerDomains.insert(domain) }
        }

        mutating func imageURL(_ value: String, known: ImageSource?) -> String? {
            let decision = known?.decision ?? URLPolicy.classify(value, context: options.mode == .compose ? .composeImage : .image)
            switch decision {
            case .allow(let url):
                if let id = InlineParts.contentID(fromString: url), !inlineIDs.contains(id) { inlineIDs.append(id) }
                return url
            case .remote(let url):
                remote += 1
                if known?.isTracker ?? TrackerList.isTracker(url: url, in: options.trackerHosts) {
                    remoteTrackers += 1
                    trackers += 1
                    noteTrackerDomain(url)
                    return nil
                }
                if options.allowRemoteImages || options.mode == .compose { return url }
                blocked += 1
                return nil
            case .reject:
                return nil
            }
        }

        func filteredClasses(_ value: String) -> String? {
            let bytes = value.utf8
            var spaces = 0, previous: UInt8 = 32, ours = false, ok = !value.isEmpty
            var last2: (UInt8, UInt8) = (0, 0)
            for b in bytes {
                if b == 32 { spaces += 1; if previous == 32 { ok = false } }
                if b == 9 || b == 10 || b == 12 || b == 13 { ok = false }
                if b == 45, last2.0 | 0x20 == 111, last2.1 | 0x20 == 104 { ours = true }
                last2 = (last2.1, b)
                previous = b
            }
            if ok, !ours, previous != 32, bytes.first != 32, spaces < options.limits.maxClasses { return value }
            let classes = value.split(whereSeparator: \.isWhitespace)
                .filter { !$0.lowercased().hasPrefix("oh-") }
                .prefix(options.limits.maxClasses)
            return classes.isEmpty ? nil : classes.joined(separator: " ")
        }

        static func clampedNumeric(_ value: String) -> String {
            if value.utf8.count <= 4, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) { return value }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count == trimmed.count || trimmed.dropFirst(digits.count).lowercased() == "px" else {
                return value
            }
            guard digits.count <= 5, let n = Int(digits) else { return "10000" }
            return n > 10_000 ? "10000" : trimmed
        }

        func isTrackingPixel(_ img: Attributes) -> Bool {
            let width = Self.pixels(img["width"])
            let height = Self.pixels(img["height"])
            if let width, let height, width <= 1, height <= 1 { return true }
            if width == 0 || height == 0 { return true }
            let rawStyle = img["style"]
            guard !rawStyle.isEmpty else { return false }
            let style = rawStyle.lowercased().filter { !$0.isWhitespace }
            if style.contains("display:none") || style.contains("visibility:hidden") || style.contains("opacity:0;")
                || style.hasSuffix("opacity:0") || style.contains("max-height:0") || style.contains("max-width:0") {
                return true
            }
            if Self.styleDimension(style, "width") ?? 2 <= 1, Self.styleDimension(style, "height") ?? 2 <= 1 { return true }
            return false
        }

        static func pixels(_ value: String) -> Double? {
            let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
            let number = trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed
            return Double(number)
        }

        static func styleDimension(_ compactStyle: String, _ property: String) -> Double? {
            for declaration in compactStyle.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0] == Substring(property) else { continue }
                return pixels(String(parts[1]))
            }
            return nil
        }

        func isQuotedHistory(tag: String, attrs: Attributes) -> Bool {
            if tag == "blockquote", attrs["type"].lowercased() == "cite" { return true }
            if tag == "div" {
                let classes = attrs["class"].lowercased().split(whereSeparator: \.isWhitespace)
                if classes.contains("gmail_quote") || classes.contains("yahoo_quoted") { return true }
            }
            return false
        }

        func isForwarded(_ element: Element, tag: String) -> Bool {
            let markers = ["forwarded message", "begin forwarded message"]
            let head = ((try? element.text()) ?? "").prefix(300).lowercased()
            if markers.contains(where: head.contains) { return true }
            if tag == "blockquote", let previous = try? element.previousElementSibling() {
                let text = ((try? previous.text()) ?? "").suffix(200).lowercased()
                if markers.contains(where: text.contains) { return true }
            }
            return false
        }

        func isSignature(tag: String, attrs: Attributes) -> Bool {
            guard tag == "div" || tag == "pre", !attrs.isEmpty else { return false }
            let classes = attrs["class"].lowercased().split(whereSeparator: \.isWhitespace)
            if classes.contains("gmail_signature") || classes.contains("moz-signature") { return true }
            if attrs["data-smartmail"] == "gmail_signature" { return true }
            return tag == "div" && attrs["id"] == "Signature"
        }

        func isRestFoldMarker(_ element: Element, tag: String, attrs: Attributes) -> Bool {
            guard tag == "div" || tag == "hr" else { return false }
            if isFoldMarker(element, tag: tag, attrs: attrs) { return true }
            guard tag == "div", attrs.isEmpty else { return false }
            var candidate = element
            for _ in 0..<3 {
                let children = candidate.children()
                guard children.size() == 1, let only = children.first(),
                      !candidate.ownText().contains(where: { !$0.isWhitespace }) else { return false }
                candidate = only
                let childTag = candidate.tagNameNormal()
                let childAttrs = Attributes(candidate)
                if isFoldMarker(candidate, tag: childTag, attrs: childAttrs) { return true }
                guard childTag == "div", childAttrs.isEmpty else { return false }
            }
            return false
        }

        func isFoldMarker(_ element: Element, tag: String, attrs: Attributes) -> Bool {
            let id = attrs["id"]
            if id == "divRplyFwdMsg" || id == "appendonsend" { return true }
            if tag == "hr", id == "stopSpelling" { return true }
            if tag == "div" {
                let style = attrs["style"]
                guard !style.isEmpty else { return false }
                let compact = style.lowercased().filter { !$0.isWhitespace }
                if compact.contains("border-top:solid"),
                   ((try? element.text()) ?? "").trimmingCharacters(in: .whitespaces).hasPrefix("From:") {
                    return true
                }
            }
            return false
        }
    }

    struct Writer {
        let walker: Walker
        let transform: ColorTransform
        let colors: ColorContext?
        var bodyAttributes = ""
        var bodyClass = ""
        var bodyAttributeCSS = ""

        struct Context {
            var text: ThemeColor
            var background: ThemeColor
            var textUnknown = false
            var backgroundUnknown = false
        }

        init(walker: Walker, transform: ColorTransform, colors: ColorContext?) {
            self.walker = walker
            self.transform = transform
            self.colors = colors
        }

        mutating func write() -> String {
            var stack: [Context] = []
            if let colors { stack.append(Context(text: colors.text, background: colors.canvas)) }
            writeBody(&stack)
            var out = ""
            out.reserveCapacity(walker.textLength + walker.elements.count * 24)
            for op in walker.ops {
                switch op {
                case .text(let s):
                    out += escapeText(s)
                case .raw(let s):
                    out += s
                case .close(let tag):
                    out += "</" + tag + ">"
                    if colors != nil, stack.count > 1 { stack.removeLast() }
                case .open(let index):
                    let element = walker.elements[index]
                    var (attributes, style) = resolvedAttributes(element.attributes, style: element.style,
                                                                  link: element.tag == "a")
                    if colors != nil {
                        let context = derive(stack.last!, element: element, style: style, colorAttributes: element.attributes)
                        var next = context
                        if element.hasDirectText, !context.textUnknown, !context.backgroundUnknown {
                            let nudged = ColorRemapper.nudged(text: context.text, on: context.background)
                            if nudged != context.text {
                                style.removeAll { $0.lowerName == "color" }
                                style.append(CSSDeclaration(name: "color", value: [
                                    ColorTransform.component(nudged), .token(.whitespace), .token(.delim("!")),
                                    .token(.ident("important")),
                                ]))
                                if !attributes.contains(where: { $0.0 == "style" }) { attributes.append(("style", "")) }
                                next.text = nudged
                            }
                        }
                        if !HTMLSanitizer.voidTags.contains(element.tag) { stack.append(next) }
                    }
                    out += "<" + element.tag
                    for (key, value) in attributes {
                        if key == "style" {
                            let css = CSSSerializer.serialize(CSSWriter.tokens(style))
                            if !css.isEmpty { out += attr("style", css) }
                        } else if HTMLSanitizer.booleanAttributes.contains(key), value.isEmpty {
                            out += " " + key
                        } else {
                            out += attr(key, value)
                        }
                    }
                    out += ">"
                }
            }
            return out
        }

        mutating func writeBody(_ stack: inout [Context]) {
            let (attributes, fromAttributes) = resolvedAttributes(walker.bodyAttributes, style: [])
            var attributeCSS = fromAttributes
            for (key, value) in attributes where key == "bgcolor" || key == "text" {
                guard case .color(let c) = CSSColor.parseLegacyAttribute(value) else { continue }
                attributeCSS.append(CSSDeclaration(name: key == "bgcolor" ? "background-color" : "color",
                                                   value: [ColorTransform.component(c)]))
            }
            if let url = walker.bodyBackground {
                attributeCSS.append(CSSDeclaration(name: "background-image", value: [.token(.url(url))]))
            }
            let style = transform.apply(walker.body)
            if colors != nil, let root = stack.last {
                stack[stack.count - 1] = apply(ColorTransform.ownColors(attributeCSS + style), to: root, isLink: false)
            }
            bodyAttributeCSS = attributeCSS.isEmpty ? "" : ".oh-body{" + CSSSerializer.serialize(CSSWriter.tokens(attributeCSS)) + "}"
            var out = ""
            for (key, value) in attributes {
                switch key {
                case "bgcolor", "text", "style": continue
                case "class": bodyClass = value
                default: out += attr(key, value)
                }
            }
            let css = CSSSerializer.serialize(CSSWriter.tokens(style))
            if !css.isEmpty { out += attr("style", css) }
            bodyAttributes = out
        }

        func resolvedAttributes(_ ops: [AttributeOp], style: [CSSDeclaration],
                                link: Bool = false) -> ([(String, String)], [CSSDeclaration]) {
            var attributes: [(String, String)] = []
            var pre: [CSSDeclaration] = []
            var hasStyle = false
            for op in ops {
                switch op {
                case .plain(let k, let v): attributes.append((k, v))
                case .style: attributes.append(("style", "")); hasStyle = true
                case .color(let k, let v):
                    switch transform.attribute(k, value: v) {
                    case .keep(let kept): attributes.append((k, kept))
                    case .drop: continue
                    case .style(let d): pre.append(d)
                    }
                }
            }
            if !pre.isEmpty, !hasStyle { attributes.append(("style", "")) }
            return (attributes, pre + transform.apply(style, link: link))
        }

        func derive(_ parent: Context, element: OpenElement, style: [CSSDeclaration], colorAttributes: [AttributeOp]) -> Context {
            var own = ColorTransform.ownColors(style)
            for case .color(let key, let raw) in colorAttributes {
                let value: CSSColorValue
                switch transform.attribute(key, value: raw) {
                case .keep(let kept): value = CSSColor.parseLegacyAttribute(kept)
                default: continue
                }
                if key == "bgcolor", own.background == nil { own.background = value }
                if key == "color", own.text == nil { own.text = value }
            }
            return apply(own, to: parent, isLink: element.isLink)
        }

        func apply(_ own: (text: CSSColorValue?, background: CSSColorValue?, image: Bool), to parent: Context,
                   isLink: Bool) -> Context {
            var c = parent
            if own.image { c.backgroundUnknown = true }
            switch own.background {
            case .color(let color)?:
                c.background = color.alpha < 1 ? color.composited(over: parent.background) : color
                if !own.image { c.backgroundUnknown = false }
            case .unknown?:
                c.backgroundUnknown = true
            default:
                break
            }
            switch own.text {
            case .color(let color)?:
                c.text = color
                c.textUnknown = color.alpha == 0
            case .unknown?:
                c.textUnknown = true
            case .transparent?:
                c.textUnknown = true
            default:
                if isLink, let colors {
                    c.text = colors.link
                    c.textUnknown = false
                }
            }
            return c
        }

        func attr(_ key: String, _ value: String) -> String { " " + key + "=\"" + escapeAttribute(value) + "\"" }
    }
}

extension ColorTransform {
    static let identity = ColorTransform(mode: .none, dropColorScheme: false)

    init(mode: Mode, dropColorScheme: Bool) {
        self.mode = mode
        self.dropColorScheme = dropColorScheme
    }
}

func escapeText(_ s: String) -> String {
    guard s.utf8.contains(where: { $0 == 38 || $0 == 60 || $0 == 62 || $0 == 0 }) else { return s }
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count + 32)
    for b in s.utf8 {
        switch b {
        case 38: out += [38, 97, 109, 112, 59]
        case 60: out += [38, 108, 116, 59]
        case 62: out += [38, 103, 116, 59]
        case 0: continue
        default: out.append(b)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

func escapeAttribute(_ s: String) -> String {
    guard s.utf8.contains(where: { $0 == 38 || $0 == 60 || $0 == 62 || $0 == 34 || $0 == 39 || $0 == 0 }) else { return s }
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count + 32)
    for b in s.utf8 {
        switch b {
        case 38: out += [38, 97, 109, 112, 59]
        case 60: out += [38, 108, 116, 59]
        case 62: out += [38, 103, 116, 59]
        case 34: out += [38, 113, 117, 111, 116, 59]
        case 39: out += [38, 35, 51, 57, 59]
        case 0: continue
        default: out.append(b)
        }
    }
    return String(decoding: out, as: UTF8.self)
}
