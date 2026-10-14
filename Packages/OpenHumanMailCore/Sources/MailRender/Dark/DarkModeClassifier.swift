import Foundation
import MailTheme

public enum DarkModeTier: String, Sendable, Hashable, Codable, CaseIterable {
    case plain, selfAdapting, designed
}

public enum ColorTreatment: String, Sendable, Hashable, Codable, CaseIterable {
    case themeText
    case selfAdapting
    case original
    case remapped
}

public enum ColorOverride: String, Sendable, Hashable, Codable, CaseIterable {
    case darkColors
    case originalColors
}

public enum DarkModePolicy {
    public static func treatment(tier: DarkModeTier, appearance: ThemeAppearance, emailColors: EmailColors,
                                 override: ColorOverride? = nil) -> ColorTreatment {
        let mode: EmailColors
        switch override {
        case .originalColors?: mode = .alwaysOriginal
        case .darkColors?: mode = .alwaysAdapt
        case nil: mode = emailColors
        }
        switch (mode, tier) {
        case (.alwaysOriginal, _): return .original
        case (_, .plain): return .themeText
        case (_, .selfAdapting): return .selfAdapting
        case (.adaptWhenSafe, .designed): return .original
        case (.alwaysAdapt, .designed): return appearance == .dark ? .remapped : .original
        }
    }

    public static func colorScheme(for treatment: ColorTreatment, appearance: ThemeAppearance) -> ReaderCSS.ColorScheme {
        switch treatment {
        case .selfAdapting: return .lightDark
        case .remapped: return .dark
        case .themeText, .original: return appearance == .dark ? .dark : .light
        }
    }
}

struct DarkModeClassifier {
    private(set) var selfAdapting = false
    private(set) var designedReason: String?

    var tier: DarkModeTier {
        if selfAdapting { return .selfAdapting }
        return designedReason == nil ? .plain : .designed
    }

    mutating func noteMeta(name: String, content: String) {
        let n = name.lowercased()
        guard n == "color-scheme" || n == "supported-color-schemes" else { return }
        if content.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).contains("dark") { selfAdapting = true }
    }

    mutating func noteDarkMediaQuery() { selfAdapting = true }

    private mutating func designed(_ reason: @autoclosure () -> String) {
        if designedReason == nil { designedReason = reason() }
    }

    mutating func note(_ declarations: [CSSDeclaration], link: Bool = false) {
        guard designedReason == nil else { return }
        for d in declarations where !(link && (d.lowerName == "color" || d.lowerName == "-webkit-text-fill-color")) {
            note(d)
        }
    }

    mutating func note(_ items: [CSSItem]) {
        for item in items {
            switch item {
            case .style(let selector, let declarations): note(declarations, link: ColorTransform.isLinkOnly(selector))
            case .group(_, _, let inner): note(inner)
            case .keyframes(_, _, let frames): for f in frames { note(f.declarations) }
            }
        }
    }

    mutating func note(_ d: CSSDeclaration) {
        let name = d.lowerName
        if name == "color" || name == "-webkit-text-fill-color" {
            for c in d.value {
                guard let v = CSSColor.value(of: c) else { continue }
                if !Self.isPlainText(v) { designed("text color \(CSSSerializer.serialize(CSSWriter.flatten([c])))") }
            }
        } else if name == "background-color" {
            for c in d.value {
                guard let v = CSSColor.value(of: c) else { continue }
                if !Self.isPlainBackground(v) { designed("background \(CSSSerializer.serialize(CSSWriter.flatten([c])))") }
            }
        } else if name == "background" || name == "background-image" {
            for c in d.value {
                switch c {
                case .token(.url):
                    designed("background image")
                case .function(let f, _) where f.lowercased().contains("gradient") || f.lowercased() == "url":
                    designed("background image")
                default:
                    guard let v = CSSColor.value(of: c) else { continue }
                    if !Self.isPlainBackground(v) { designed("background \(CSSSerializer.serialize(CSSWriter.flatten([c])))") }
                }
            }
        }
    }

    mutating func noteAttribute(_ name: String, value: String) {
        switch name {
        case "bgcolor":
            if !Self.isPlainBackground(CSSColor.parseLegacyAttribute(value)) { designed("bgcolor=\(value)") }
        case "color", "text":
            if !Self.isPlainText(CSSColor.parseLegacyAttribute(value)) { designed("\(name)=\(value)") }
        case "background":
            designed("background attribute")
        default:
            break
        }
    }

    static func isPlainText(_ value: CSSColorValue) -> Bool {
        switch value {
        case .transparent, .inherited: return true
        case .unknown: return false
        case .color(let c):
            let opaque = c.overWhite
            let lightness = opaque.cieLightness
            return lightness < 30 || (OKLCH(opaque).c < 0.03 && lightness < 90)
        }
    }

    static func isPlainBackground(_ value: CSSColorValue) -> Bool {
        switch value {
        case .transparent, .inherited: return true
        case .unknown: return false
        case .color(let c):
            let o = OKLCH(c.overWhite)
            return o.l >= 0.985 && o.c < 0.02
        }
    }

    static func isNearBlack(_ c: ThemeColor) -> Bool { c.overWhite.cieLightness < 30 }
}
