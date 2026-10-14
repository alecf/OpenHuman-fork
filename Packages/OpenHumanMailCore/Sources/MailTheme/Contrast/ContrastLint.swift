import Foundation

public struct ContrastCheck: Sendable, Hashable {
    public let label: String
    public let path: String
    public let background: String
    public let ratio: Double
    public let required: Double

    public var passes: Bool { ratio >= required }
    public var roundedRatio: Double { (ratio * 100).rounded() / 100 }
}

public enum ContrastLint {
    public static let refusalThreshold = 3.0

    private struct Pair {
        let fg: ColorToken
        let bg: ColorToken
        let required: Double
        let label: String
    }

    private static func pair(_ fg: ColorToken, _ bg: ColorToken, _ required: Double, _ label: String? = nil) -> Pair {
        Pair(fg: fg, bg: bg, required: required, label: label ?? "\(fg.rawValue) on \(bg.rawValue)")
    }

    private static let themePairs: [Pair] = [
        pair(.textPrimary, .bgWindow, 4.5),
        pair(.textPrimary, .bgRowSelected, 4.5),
        pair(.textSecondary, .bgWindow, 4.5),
        pair(.textSecondary, .bgRowSelected, 4.5),
        pair(.textSecondary, .bgSidebar, 4.5),
        pair(.textSecondary, .bgElevated, 4.5),
        pair(.textTertiary, .bgWindow, 4.5),
        pair(.textTertiary, .bgRowSelected, 3.0),
        pair(.textTertiary, .bgSidebar, 4.5),
        pair(.textTertiary, .bgSunken, 4.5),
        pair(.textTertiary, .bgRowHover, 4.5),
        pair(.textDanger, .bgWindow, 4.5),
        pair(.textSuccess, .bgWindow, 4.5),
        pair(.textSuccess, .bgRowSelected, 4.5),
        pair(.textWarning, .bgWindow, 4.5),
        pair(.textAI, .bgWindow, 4.5),
        pair(.textAI, .bgElevated, 4.5),
        pair(.textPrimary, .bgSearchHighlight, 4.5, "text.primary on search.highlight"),
        pair(.textWarning, .bgWarningSubtle, 4.5),
        pair(.textDanger, .bgDangerSubtle, 4.5),
        pair(.textAI, .bgAISubtle, 4.5),
        pair(.textPrimary, .bgAISubtle, 4.5),
        pair(.textOnToast, .bgToast, 4.5, "toast.text on bg.toast"),
        pair(.textOnToastSecondary, .bgToast, 4.5, "toast.textSecondary on bg.toast"),
        pair(.textOnToastDanger, .bgToast, 3.0, "toast.danger on bg.toast (glyph)"),
        pair(.borderOnToast, .bgToast, 3.0, "border.onToast on bg.toast (non-text)"),
        pair(.keycapText, .keycapBg, 4.5),
        pair(.borderControl, .bgWindow, 3.0, "border.control on bg.window (non-text)"),
        pair(.textDisabled, .bgWindow, 0, "text.disabled on bg.window (exempt; informational)"),
        pair(.bgRowSelected, .bgWindow, 0, "bg.row.selected vs bg.window (fill only; cursor bar carries the 3:1)"),
        pair(.textLink, .bgWindow, 4.5),
    ]

    private static let accentPairs: [Pair] = [
        pair(.accentText, .bgWindow, 4.5),
        pair(.accentText, .bgRowSelected, 4.5),
        pair(.accentOnFill, .accentFill, 4.5),
        pair(.accentOnFill, .accentFillHover, 4.5),
        pair(.accentRing, .bgWindow, 3.0, "focus.ring on bg.window (non-text)"),
        pair(.accentRing, .bgRowSelected, 3.0, "focus.ring on bg.row.selected"),
        pair(.accentRing, .bgWindow, 3.0, "status.unread(dot=ring) on bg.window"),
        pair(.textPrimary, .accentSubtle, 4.5),
    ]

    public static func checks(for tokens: ThemeTokens, accentID: String? = nil) -> [ContrastCheck] {
        let prefix = accentID.map { "[\($0)] " } ?? ""
        return themePairs.map { check($0, tokens, prefix: "") } + accentPairs.map { check($0, tokens, prefix: prefix) }
    }

    public static func issues(for tokens: ThemeTokens) -> [ThemeIssue] {
        var issues: [ThemeIssue] = []
        let primary = tokens.textPrimary.contrastRatio(on: tokens.bgWindow)
        if primary < refusalThreshold {
            issues.append(.refused(.contrastRefused, path(.textPrimary),
                                   "\(format(primary)):1 on bg.window; text needs at least 3:1 to load (4.5:1 recommended)"))
        }
        for check in checks(for: tokens) where !check.passes {
            if check.label == "text.primary on bg.window", primary < refusalThreshold { continue }
            issues.append(.warning(.contrast, check.path,
                                   "\(format(check.ratio)):1 on \(check.background) (needs \(format(check.required)):1) — loaded with warning"))
        }
        return issues
    }

    public static func format(_ ratio: Double) -> String {
        var text = String(format: "%.2f", ratio)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text += "0" }
        return text
    }

    private static func check(_ pair: Pair, _ tokens: ThemeTokens, prefix: String) -> ContrastCheck {
        let fg = tokens.color(pair.fg)
        let bg = tokens.color(pair.bg)
        return ContrastCheck(label: prefix + pair.label, path: path(pair.fg), background: pair.bg.rawValue,
                             ratio: fg.contrastRatio(on: bg), required: pair.required)
    }

    private static func path(_ token: ColorToken) -> String {
        token.rawValue.hasPrefix("accent.") ? token.rawValue : "semantic.color.\(token.rawValue)"
    }
}
