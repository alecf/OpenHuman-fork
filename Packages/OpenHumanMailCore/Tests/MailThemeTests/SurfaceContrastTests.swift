import Foundation
import Testing
@testable import MailTheme

@Suite struct SurfaceContrastTests {
    private static let darkThemes = [BuiltinThemeID.dark, BuiltinThemeID.midnight, BuiltinThemeID.systemDark]
    private static let themes = [BuiltinThemeID.light, BuiltinThemeID.paper, BuiltinThemeID.systemLight] + darkThemes

    private static func everyResolvedTheme() -> [(String, ThemeTokens)] {
        let library = ThemeLibrary.builtIn
        var result: [(String, ThemeTokens)] = []
        for themeID in themes {
            for accent in BuiltinThemeID.accents {
                for increase in [false, true] {
                    let appearance: ThemeAppearance = darkThemes.contains(themeID) ? .dark : .light
                    let tokens = library.resolve(themeID: themeID, appearance: appearance,
                                                 preferences: ThemePreferences(accentID: accent),
                                                 increaseContrast: increase).tokens
                    result.append(("\(themeID) \(accent) increaseContrast=\(increase)", tokens))
                }
            }
        }
        return result
    }

    @Test func tertiaryTextValuesAreTheProposedOnes() {
        let library = ThemeLibrary.builtIn
        func tertiary(_ id: String, _ appearance: ThemeAppearance) -> String {
            library.resolve(themeID: id, appearance: appearance, preferences: ThemePreferences()).tokens.textTertiary.css
        }
        #expect(tertiary(BuiltinThemeID.light, .light) == "#686e78")
        #expect(tertiary(BuiltinThemeID.paper, .light) == "#6a645a")
        #expect(tertiary(BuiltinThemeID.systemDark, .dark) == "#9c9c9c")
        #expect(tertiary(BuiltinThemeID.dark, .dark) == "#9ca3ad")
        #expect(tertiary(BuiltinThemeID.midnight, .dark) == "#848d9b")
        #expect(tertiary(BuiltinThemeID.systemLight, .light) == "#666666")
    }

    @Test func tertiaryTextPassesOnEverySurfaceItIsDrawnOn() {
        for (label, t) in Self.everyResolvedTheme() {
            for (name, surface) in [("bg.window", t.bgWindow), ("bg.sidebar", t.bgSidebar), ("bg.sunken", t.bgSunken),
                                    ("bg.row.hover", t.bgRowHover), ("bg.elevated", t.bgElevated)] {
                #expect(t.textTertiary.contrastRatio(on: surface) >= 4.5, "text.tertiary on \(name): \(label)")
            }
            #expect(t.textTertiary.contrastRatio(on: t.bgRowSelected) >= 3, "text.tertiary on bg.row.selected: \(label)")
            #expect(t.textSecondary.contrastRatio(on: t.bgRowSelected) >= 4.5, "text.secondary on the cursor: \(label)")
        }
    }

    @Test func swipeFillsHoldTheirWhiteTitleInEveryTheme() {
        let light = ThemeTokens.light.component.swipe
        for (label, t) in Self.everyResolvedTheme() {
            let swipe = t.component.swipe
            #expect(swipe == light, "swipe colors are the same in every theme: \(label)")
            for (name, fill) in [("done", swipe.done), ("snooze", swipe.snooze), ("trash", swipe.trash)] {
                #expect(swipe.text.contrastRatio(on: fill) >= 4.5, "swipe.text on swipe.\(name): \(label)")
            }
        }
        let ratios = [light.done, light.snooze, light.trash].map { (light.text.contrastRatio(on: $0) * 100).rounded() / 100 }
        #expect(ratios == [5.88, 6.67, 6.57])
    }

    @Test func sidebarSelectionCarriesABarAndReadableText() {
        for (label, t) in Self.everyResolvedTheme() {
            let sidebar = t.component.labelSidebar
            #expect(sidebar.bar.contrastRatio(on: t.bgSidebar) >= 3, "labelSidebar.bar on bg.sidebar: \(label)")
            #expect(sidebar.bar.contrastRatio(on: sidebar.bgSelected) >= 3, "labelSidebar.bar on its plate: \(label)")
            #expect(sidebar.header.contrastRatio(on: t.bgSidebar) >= 4.5, "labelSidebar.header: \(label)")
            #expect(sidebar.count.contrastRatio(on: sidebar.bgSelected) >= 4.5, "labelSidebar.count on the plate: \(label)")
            #expect(t.textPrimary.contrastRatio(on: sidebar.bgSelected) >= 4.5, "title on the plate: \(label)")
            #expect(sidebar.iconSelected.contrastRatio(on: sidebar.bgSelected) >= 3, "selected icon: \(label)")
        }
        let t = ThemeTokens.light.component.labelSidebar
        #expect([t.width, t.rowHeight, t.insetX] == [220, 28, 8] && t.radius == ThemeTokens.light.radiusMD)
    }

    @Test func toastPartsReadOnTheInverseSurface() {
        for (label, t) in Self.everyResolvedTheme() {
            let toast = t.component.toast
            #expect(toast.textSecondary.contrastRatio(on: toast.bg) >= 4.5, "toast.textSecondary: \(label)")
            #expect(toast.danger.contrastRatio(on: toast.bg) >= 3, "toast.danger: \(label)")
            let cap = toast.keycapBg.composited(over: toast.bg)
            #expect(toast.keycapText.contrastRatio(on: cap) >= 4.5, "toast.keycapText on toast.keycapBg: \(label)")
            #expect(cap.contrastRatio(on: toast.bg) >= 3, "toast.keycapBg on bg.toast: \(label)")
        }
    }

    @Test func theLintChecksTheNewPairs() {
        let labels = Set(ContrastLint.checks(for: .light).map(\.label))
        for pair in ["text.tertiary on bg.sidebar", "text.tertiary on bg.sunken", "text.tertiary on bg.row.hover",
                     "toast.textSecondary on bg.toast", "toast.danger on bg.toast (glyph)",
                     "border.onToast on bg.toast (non-text)"] {
            #expect(labels.contains(pair), "\(pair)")
        }
        for tokens in [ThemeTokens.light, .dark, .paper, .midnight] {
            let failing = ContrastLint.checks(for: tokens).filter { !$0.passes }.map(\.label)
            #expect(failing.isEmpty, "\(failing)")
        }
    }
}
