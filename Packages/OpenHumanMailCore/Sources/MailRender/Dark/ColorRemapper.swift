import Foundation
import MailTheme

public enum ColorRemapper {
    public enum Role: Sendable { case text, background }

    public static func remap(_ color: ThemeColor, role: Role) -> ThemeColor {
        var o = OKLCH(color)
        switch role {
        case .background where o.l > 0.6, .text where o.l < 0.4:
            o.l = 1 - o.l
            o.c *= 0.9
            return quantized(o.srgb)
        default:
            return color
        }
    }

    public static func nudged(text: ThemeColor, on background: ThemeColor, minimum: Double = 4.5) -> ThemeColor {
        let bg = background.alpha < 1 ? background.composited(over: ThemeColor(red: 0, green: 0, blue: 0)) : background
        let fg = text.composited(over: bg)
        if fg.contrastRatio(on: bg) >= minimum { return text }
        let target = minimum + 0.1
        let base = OKLCH(fg)
        func candidate(_ l: Double) -> ThemeColor {
            var o = base
            o.l = l
            o.alpha = 1
            return quantized(o.srgb)
        }
        var best: (delta: Double, color: ThemeColor)?
        for end in [1.0, 0.0] where candidate(end).contrastRatio(on: bg) >= target {
            var failing = base.l, passing = end
            for _ in 0..<32 {
                let mid = (failing + passing) / 2
                if candidate(mid).contrastRatio(on: bg) >= target { passing = mid } else { failing = mid }
            }
            let delta = abs(passing - base.l)
            if best == nil || delta < best!.delta { best = (delta, candidate(passing)) }
        }
        if let best { return best.color }
        let white = ThemeColor(red: 1, green: 1, blue: 1), black = ThemeColor(red: 0, green: 0, blue: 0)
        return white.contrastRatio(on: bg) >= black.contrastRatio(on: bg) ? white : black
    }

    static func quantized(_ c: ThemeColor) -> ThemeColor {
        func b(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        return ThemeColor(r8: b(c.red), g8: b(c.green), b8: b(c.blue), alpha: c.alpha)
    }
}

struct ColorTransform {
    enum Mode { case none, themeText, remap }

    let mode: Mode
    let dropColorScheme: Bool

    init(treatment: ColorTreatment) {
        switch treatment {
        case .themeText: mode = .themeText
        case .remapped: mode = .remap
        case .original, .selfAdapting: mode = .none
        }
        dropColorScheme = treatment != .selfAdapting
    }

    var isIdentity: Bool { mode == .none && !dropColorScheme }

    static let textVariable: CSSComponent = .function("var", [.token(.ident("--oh-text"))])
    static let secondaryTextVariable: CSSComponent = .function("var", [.token(.ident("--oh-text-secondary"))])

    static let foregroundColorProperties: Set<String> = [
        "color", "border", "border-color", "border-top", "border-right", "border-bottom", "border-left",
        "border-top-color", "border-right-color", "border-bottom-color", "border-left-color", "border-block",
        "border-inline", "border-block-color", "border-inline-color", "outline", "outline-color", "text-decoration",
        "text-decoration-color", "text-shadow", "box-shadow", "column-rule", "column-rule-color", "caret-color",
        "-webkit-text-fill-color", "-webkit-text-stroke", "-webkit-text-stroke-color", "text-emphasis",
        "text-emphasis-color", "accent-color", "fill", "stroke", "stop-color", "flood-color", "lighting-color",
    ]

    static func role(of property: String) -> ColorRemapper.Role? {
        if property == "background" || property == "background-color" { return .background }
        return foregroundColorProperties.contains(property) ? .text : nil
    }

    func apply(_ declarations: [CSSDeclaration], link: Bool = false) -> [CSSDeclaration] {
        guard !isIdentity else { return declarations }
        return declarations.compactMap { d in
            let name = d.lowerName
            if dropColorScheme, name == "color-scheme" { return nil }
            switch mode {
            case .none:
                return d
            case .themeText:
                if name == "color" || name == "-webkit-text-fill-color" {
                    return CSSDeclaration(name: d.name, value: d.value.map { link ? linkColor($0) : themeTextColor($0) })
                }
                if name == "background" || name == "background-color" {
                    return CSSDeclaration(name: d.name, value: d.value.map(themeBackground))
                }
                return d
            case .remap:
                guard let role = Self.role(of: name) else { return d }
                return CSSDeclaration(name: d.name, value: d.value.map { remapped($0, role: role) })
            }
        }
    }

    func apply(_ items: [CSSItem]) -> [CSSItem] {
        guard !isIdentity else { return items }
        return items.map { item in
            switch item {
            case .style(let selector, let declarations):
                return .style(selector: selector, declarations: apply(declarations, link: Self.isLinkOnly(selector)))
            case .group(let keyword, let prelude, let inner):
                return .group(keyword: keyword, prelude: prelude, items: apply(inner))
            case .keyframes(let keyword, let prelude, let frames):
                return .keyframes(keyword: keyword, prelude: prelude,
                                  frames: frames.map { CSSKeyframe(selector: $0.selector, declarations: apply($0.declarations)) })
            }
        }
    }

    static let linkVariable: CSSComponent = .function("var", [.token(.ident("--oh-link"))])

    private func linkColor(_ c: CSSComponent) -> CSSComponent {
        guard case .color? = CSSColor.value(of: c) else { return c }
        return Self.linkVariable
    }

    static func isLinkOnly(_ selector: [CSSToken]) -> Bool {
        let pseudo: Set<String> = ["link", "visited", "hover", "active", "focus", "any-link"]
        let msoClasses: Set<String> = ["msohyperlink", "msohyperlinkfollowed"]
        var parts: [[CSSToken]] = [[]]
        for t in selector { if t == .comma { parts.append([]) } else { parts[parts.count - 1].append(t) } }
        for part in parts {
            var tokens = part.filter { $0 != .whitespace }
            if tokens.count >= 2, tokens[0] == .delim("."), tokens[1] == .ident("oh-body") { tokens.removeFirst(2) }
            var selectsLink = false
            var i = 0
            while i < tokens.count {
                switch tokens[i] {
                case .ident(let n) where n.lowercased() == "a": selectsLink = true
                case .ident(let n) where n.lowercased() == "span": break
                case .delim("."):
                    guard i + 1 < tokens.count, case .ident(let c) = tokens[i + 1], msoClasses.contains(c.lowercased()) else { return false }
                    selectsLink = true
                    i += 1
                case .colon:
                    guard i + 1 < tokens.count, case .ident(let p) = tokens[i + 1], pseudo.contains(p.lowercased()) else { return false }
                    i += 1
                default:
                    return false
                }
                i += 1
            }
            if !selectsLink { return false }
        }
        return true
    }

    private func themeTextColor(_ c: CSSComponent) -> CSSComponent {
        guard case .color(let color)? = CSSColor.value(of: c) else { return c }
        return DarkModeClassifier.isNearBlack(color) ? Self.textVariable : Self.secondaryTextVariable
    }

    private func themeBackground(_ c: CSSComponent) -> CSSComponent {
        guard let v = CSSColor.value(of: c), case .color = v, DarkModeClassifier.isPlainBackground(v) else { return c }
        return .token(.ident("transparent"))
    }

    private func remapped(_ c: CSSComponent, role: ColorRemapper.Role) -> CSSComponent {
        guard case .color(let color)? = CSSColor.value(of: c) else { return c }
        return Self.component(ColorRemapper.remap(color, role: role))
    }

    static func component(_ color: ThemeColor) -> CSSComponent {
        let q = ColorRemapper.quantized(color)
        let hex = String(format: "%02x%02x%02x", Int((q.red * 255).rounded()), Int((q.green * 255).rounded()),
                         Int((q.blue * 255).rounded()))
        if q.alpha >= 1 { return .token(.hash(hex)) }
        let channels: [CSSComponent] = [
            .token(.number(String(Int((q.red * 255).rounded())))), .token(.comma),
            .token(.number(String(Int((q.green * 255).rounded())))), .token(.comma),
            .token(.number(String(Int((q.blue * 255).rounded())))), .token(.comma),
            .token(.number(String(format: "%.3f", q.alpha))),
        ]
        return .function("rgba", channels)
    }

    enum AttributeResult: Equatable {
        case keep(String)
        case drop
        case style(CSSDeclaration)
    }

    func attribute(_ name: String, value: String) -> AttributeResult {
        let parsed = CSSColor.parseLegacyAttribute(value)
        switch mode {
        case .none:
            return .keep(value)
        case .themeText:
            guard case .color(let color) = parsed else { return .keep(value) }
            if name == "bgcolor" {
                return DarkModeClassifier.isPlainBackground(parsed) ? .drop : .keep(value)
            }
            let variable = DarkModeClassifier.isNearBlack(color) ? Self.textVariable : Self.secondaryTextVariable
            return .style(CSSDeclaration(name: "color", value: [variable]))
        case .remap:
            guard case .color(let color) = parsed else { return .keep(value) }
            let mapped = ColorRemapper.remap(color, role: name == "bgcolor" ? .background : .text)
            return .keep(ColorRemapper.quantized(mapped).css)
        }
    }

    static func ownColors(_ declarations: [CSSDeclaration]) -> (text: CSSColorValue?, background: CSSColorValue?, image: Bool) {
        var text: CSSColorValue?, background: CSSColorValue?, image = false
        for d in declarations {
            switch d.lowerName {
            case "color":
                for c in d.value { if let v = CSSColor.value(of: c) { text = v; break } }
                if d.value.contains(where: { if case .function(let f, _) = $0 { return f.lowercased() == "var" }; return false }) {
                    text = .unknown
                }
            case "background-color":
                for c in d.value { if let v = CSSColor.value(of: c) { background = v; break } }
            case "background":
                var found: CSSColorValue?
                for c in d.value {
                    switch c {
                    case .token(.url): image = true
                    case .function(let f, _) where f.lowercased().contains("gradient"): image = true
                    default: if found == nil, let v = CSSColor.value(of: c) { found = v }
                    }
                }
                background = found ?? .transparent
            case "background-image":
                image = d.value.contains { c in
                    if case .token(.ident(let i)) = c, i.lowercased() == "none" { return false }
                    if case .token(.whitespace) = c { return false }
                    return true
                }
            default:
                break
            }
        }
        return (text, background, image)
    }
}
