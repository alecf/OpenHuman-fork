import Foundation
import MailModel
import MailTheme
import SwiftSoup
import Testing
@testable import MailRender

struct RenderVariant: CustomTestStringConvertible, Sendable, Hashable {
    let appearance: ThemeAppearance
    let allowRemote: Bool
    let override: ColorOverride?

    var testDescription: String {
        "\(appearance.rawValue)\(override == .darkColors ? "+remap" : "")/\(allowRemote ? "images" : "blocked")"
    }

    static let all: [RenderVariant] = [false, true].flatMap { remote in
        [RenderVariant(appearance: .light, allowRemote: remote, override: nil),
         RenderVariant(appearance: .dark, allowRemote: remote, override: nil),
         RenderVariant(appearance: .dark, allowRemote: remote, override: .darkColors)]
    }

    var theme: ThemeTokens { appearance == .dark ? .dark : .light }

    var renderer: MessageRenderer { MessageRenderer(theme: theme, appearance: appearance, emailColors: .adaptWhenSafe) }

    var context: RenderContext { RenderContext(allowRemoteImages: allowRemote, colorOverride: override) }

    func render(_ html: String) -> RenderedMessage? {
        guard case .html(let r) = renderer.render(MessageContent(html: html, text: nil), context: context) else { return nil }
        return r
    }
}

enum SafetyInvariants {
    static let allowedElements: Set<String> = HTMLSanitizer.allowedTags.union(["html", "head", "body", "meta", "style"])
    static let ourMetas: Set<String> = ["charset", "Content-Security-Policy", "referrer"]
    static let ourClasses: [String: Set<String>] = [
        "oh-body": ["div"], "oh-original": ["div"], "oh-card": ["div"], "oh-paper": ["div"],
        "oh-quoted": ["details"], "oh-signature": ["details"], "oh-placeholder": ["span"], "oh-blocked": ["img"],
    ]

    static func violations(in document: String, allowRemote: Bool = false) throws -> [String] {
        var problems: [String] = []
        let doc = try SwiftSoup.parse(document)
        let lower = document.lowercased()
        for needle in ["<script", "<iframe", "<object", "<embed", "<form", "<svg", "<math", "<base", "<link",
                       "<textarea", "<input", "<template", "<noscript"] where lower.contains(needle) {
            problems.append("contains \(needle)")
        }
        let valueNeedles = ["javascript:", "vbscript:", "srcset", "expression(", "-moz-binding", "behavior:", "invert(",
                            "hue-rotate(", "user-modify"]
        for style in try doc.select("style").array() {
            let css = style.data().lowercased()
            for needle in valueNeedles where css.contains(needle) { problems.append("stylesheet contains \(needle)") }
        }
        var roots = 0, wrappers = 0
        for element in try doc.getAllElements().array() {
            let tag = element.tagNameNormal()
            if tag == "#root" { continue }
            if !allowedElements.contains(tag) { problems.append("element <\(tag)>") }
            if tag == "meta" {
                let key = element.hasAttr("charset") ? "charset"
                    : (try? element.attr("http-equiv")).flatMap { $0.isEmpty ? nil : $0 } ?? ((try? element.attr("name")) ?? "")
                if !ourMetas.contains(key) { problems.append("foreign meta \(key)") }
            }
            for attribute in element.getAttributes()?.asList() ?? [] {
                let key = attribute.getKey().lowercased()
                let value = attribute.getValue()
                if key.hasPrefix("on") { problems.append("handler \(key) on <\(tag)>") }
                if key == "srcset" { problems.append("srcset on <\(tag)>") }
                if key != "title", key != "alt" {
                    let lowerValue = value.lowercased()
                    for needle in valueNeedles where lowerValue.contains(needle) { problems.append("\(key) contains \(needle)") }
                }
                switch key {
                case "href":
                    if !["http:", "https:", "mailto:"].contains(where: { value.lowercased().hasPrefix($0) }) {
                        problems.append("href \(value)")
                    }
                case "src", "background":
                    let ok = value.hasPrefix("ohcid:") || value.lowercased().hasPrefix("data:image/")
                        || (allowRemote && (value.hasPrefix("https:") || value.hasPrefix("http:")))
                    if !ok { problems.append("\(key) \(value.prefix(80))") }
                case "style":
                    problems += cssProblems(value, allowRemote: allowRemote).map { "style on <\(tag)>: \($0)" }
                case "target", "formaction", "action", "srcdoc", "xlink:href", "cite", "ping", "poster", "data":
                    problems.append("\(key) on <\(tag)>")
                case "id":
                    if value == "oh-root" {
                        roots += 1
                        if tag != "div" || element.parent()?.tagNameNormal() != "body" { problems.append("spoofed oh-root") }
                    } else if tag == "style", ["oh-base", "oh-structure", "oh-body-attributes"].contains(value) {
                        break
                    } else if value.lowercased().hasPrefix("oh-") {
                        problems.append("id \(value) on <\(tag)>")
                    }
                case "class":
                    for c in value.split(separator: " ").map(String.init) where c.lowercased().hasPrefix("oh-") {
                        if c == "oh-body" { wrappers += 1 }
                        if !(ourClasses[c]?.contains(tag) ?? false) { problems.append("class \(c) on <\(tag)>") }
                    }
                default:
                    break
                }
            }
            if tag == "a", element.hasAttr("href"), (try? element.attr("rel")) != "noopener noreferrer" {
                problems.append("link without rel")
            }
            if tag == "style" {
                let id = (try? element.attr("id")) ?? ""
                problems += cssProblems(element.data(), allowRemote: allowRemote).map { "stylesheet: \($0)" }
                if id != "oh-base", id != "oh-structure", id != "oh-body-attributes" {
                    problems += unscopedSelectors(element.data()).map { "unscoped selector: \($0)" }
                }
            }
        }
        if roots != 1 { problems.append("\(roots) #oh-root elements") }
        if wrappers != 1 { problems.append("\(wrappers) .oh-body wrappers") }
        return problems
    }

    static func cssProblems(_ css: String, allowRemote: Bool) -> [String] {
        var problems: [String] = []
        let tokens = CSSTokenizer.tokenize(css)
        func check(_ u: String) {
            let ok = u.hasPrefix("ohcid:") || u.lowercased().hasPrefix("data:image/")
                || (allowRemote && (u.hasPrefix("https:") || u.hasPrefix("http:")))
            if !ok { problems.append("url(\(u.prefix(80)))") }
        }
        for (i, token) in tokens.enumerated() {
            switch token {
            case .url(let u):
                check(u)
            case .function(let f) where f.lowercased() == "url":
                let args = tokens[(i + 1)...].prefix { $0 != .closeParen }.filter { $0 != .whitespace }
                if args.count == 1, case .string(let u) = args.first! { check(u) } else { problems.append("url() form \(args)") }
            case .function(let f) where ["image-set", "-webkit-image-set", "expression", "src", "image",
                                         "cross-fade", "-webkit-cross-fade", "element", "paint", "invert",
                                         "hue-rotate", "-webkit-canvas"].contains(f.lowercased()):
                problems.append("function \(f)(")
            case .atKeyword(let k) where !["media", "supports", "keyframes", "-webkit-keyframes"].contains(k.lowercased()):
                problems.append("@\(k)")
            case .ident(let p) where ["behavior", "-moz-binding", "-webkit-user-modify"].contains(p.lowercased()):
                problems.append("property \(p)")
            default:
                break
            }
        }
        let compact = css.lowercased().filter { !$0.isWhitespace }
        if compact.contains("position:fixed") || compact.contains("position:sticky") { problems.append("position fixed/sticky") }
        return problems
    }

    static func unscopedSelectors(_ css: String) -> [String] {
        var problems: [String] = []
        func walk(_ components: [CSSComponent]) {
            var prelude: [CSSComponent] = []
            var atRule: String?
            for c in components {
                switch c {
                case .token(.atKeyword(let k)) where prelude.isEmpty && atRule == nil:
                    atRule = k.lowercased()
                case .block(.openCurly, let inner):
                    if let atRule {
                        if atRule == "media" || atRule == "supports" { walk(inner) }
                    } else {
                        let tokens = CSSWriter.flatten(prelude).filter { $0 != .whitespace }
                        var parts: [[CSSToken]] = [[]]
                        for t in tokens { if t == .comma { parts.append([]) } else { parts[parts.count - 1].append(t) } }
                        for part in parts where !(part.count >= 2 && part[0] == .delim(".") && part[1] == .ident("oh-body")) {
                            problems.append(CSSSerializer.serialize(part))
                        }
                    }
                    prelude = []
                    atRule = nil
                case .token(.semicolon) where atRule != nil:
                    prelude = []
                    atRule = nil
                default:
                    if atRule == nil { prelude.append(c) }
                }
            }
        }
        walk(CSSSanitizer.parseComponents(CSSTokenizer.tokenize(css)))
        return problems
    }
}

enum ContrastAudit {
    struct Failure: CustomStringConvertible {
        let tag: String
        let text: String
        let ratio: Double
        var description: String { "<\(tag)> \"\(text.prefix(30))\" \(String(format: "%.2f", ratio)):1" }
    }

    static func failures(in document: String, theme: ThemeTokens, minimum: Double = 4.5) throws -> [Failure] {
        let doc = try SwiftSoup.parse(document)
        guard let root = try doc.getElementById("oh-root") else { return [] }
        struct Context { var text: ThemeColor; var background: ThemeColor; var unknown: Bool }
        var wrapperDeclarations: [CSSDeclaration] = []
        if let rule = try doc.getElementById("oh-body-attributes")?.data(), rule.hasPrefix(".oh-body{") {
            var s = CSSSanitizer(allowRemoteImages: true)
            wrapperDeclarations = s.declarations(String(rule.dropFirst(".oh-body{".count).dropLast()))
        }
        var failures: [Failure] = []
        var stack: [(Element, Context)] = [(root, Context(text: theme.textPrimary, background: theme.bgCard, unknown: false))]
        while let (element, parent) = stack.popLast() {
            for child in element.children() {
                let tag = child.tagNameNormal()
                if tag == "summary" || child.hasClass("oh-placeholder") { continue }
                var s = CSSSanitizer(allowRemoteImages: true)
                var declarations = s.declarations((try? child.attr("style")) ?? "")
                if child.hasClass("oh-body") { declarations = wrapperDeclarations + declarations }
                var own = ColorTransform.ownColors(declarations)
                if own.background == nil, child.hasAttr("bgcolor") {
                    own.background = CSSColor.parseLegacyAttribute((try? child.attr("bgcolor")) ?? "")
                }
                if own.text == nil, child.hasAttr("color") {
                    own.text = CSSColor.parseLegacyAttribute((try? child.attr("color")) ?? "")
                }
                var c = parent
                if own.image { c.unknown = true }
                switch own.background {
                case .color(let col)?: c.background = col.alpha < 1 ? col.composited(over: parent.background) : col
                case .unknown?: c.unknown = true
                default: break
                }
                switch own.text {
                case .color(let col)?: c.text = col
                case .unknown?, .transparent?: c.unknown = true
                default: if tag == "a", child.hasAttr("href") { c.text = theme.accentText }
                }
                let ownText = child.ownText().trimmingCharacters(in: .whitespacesAndNewlines)
                if !ownText.isEmpty, !c.unknown {
                    let ratio = c.text.composited(over: c.background).contrastRatio(on: c.background)
                    if ratio < minimum - 0.005 { failures.append(Failure(tag: tag, text: ownText, ratio: ratio)) }
                }
                stack.append((child, c))
            }
        }
        return failures
    }
}
