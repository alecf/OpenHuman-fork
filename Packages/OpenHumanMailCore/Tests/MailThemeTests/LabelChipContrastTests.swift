import Testing
@testable import MailTheme

@Suite struct LabelChipContrastTests {
    static let darkThemes = [BuiltinThemeID.dark, BuiltinThemeID.midnight, BuiltinThemeID.systemDark]
    static let themes = [BuiltinThemeID.light, BuiltinThemeID.paper, BuiltinThemeID.systemLight] + darkThemes

    static func everyResolvedTheme() -> [(String, ThemeTokens)] {
        let library = ThemeLibrary.builtIn
        var result: [(String, ThemeTokens)] = []
        for themeID in themes {
            for accent in BuiltinThemeID.accents {
                for increase in [false, true] {
                    let appearance: ThemeAppearance = darkThemes.contains(themeID) ? .dark : .light
                    let t = library.resolve(themeID: themeID, appearance: appearance,
                                            preferences: ThemePreferences(accentID: accent), increaseContrast: increase).tokens
                    result.append(("\(themeID) \(accent) increaseContrast=\(increase)", t))
                }
            }
        }
        return result
    }

    @Test func everyChipTextReadsOnItsFill() {
        for (label, t) in Self.everyResolvedTheme() {
            for hue in LabelChipHue.allCases {
                let pair = t.labelChip(hue)
                #expect(pair.bg.alpha == 1, "\(hue) fill is opaque: \(label)")
                #expect(pair.text.contrastRatio(on: pair.bg) >= 4.5, "\(hue) chip text: \(label)")
            }
            #expect(t.labelChip(.neutral) == (t.component.row.chipBg, t.component.row.chipText), "neutral: \(label)")
        }
    }

    @Test func lightAndDarkThemesTakeTheirOwnPairs() {
        let darkThemes = Self.darkThemes
        for (label, t) in Self.everyResolvedTheme() {
            let dark = darkThemes.contains { label.hasPrefix($0 + " ") }
            let fills = LabelChipHue.named.map { t.labelChip($0).bg }
            #expect(Set(fills).count == LabelChipHue.named.count, "eight distinct fills: \(label)")
            for hue in LabelChipHue.named {
                let pair = t.labelChip(hue)
                let fillIsLighter = pair.bg.relativeLuminance > pair.text.relativeLuminance
                #expect(fillIsLighter != dark, "\(hue): \(label)")
            }
        }
        #expect(ThemeTokens.light.labelChip(.coral) == (ThemeColor(hex: "#FDE4DA")!, ThemeColor(hex: "#93300F")!))
        #expect(ThemeTokens.dark.labelChip(.lavender) == (ThemeColor(hex: "#30285A")!, ThemeColor(hex: "#C9BCFA")!))
    }

    @Test func theCursorTokenIsTheAccentBandAndTheFocusEdgeIsFourPoints() {
        for (label, t) in Self.everyResolvedTheme() {
            #expect(t.component.row.bgCursor == t.accentSubtle, "row.bgCursor: \(label)")
            #expect(t.component.thread.focusEdgeWidth == 4, "thread.focusEdgeWidth: \(label)")
            #expect(t.component.row.cursorBarWidth == 3, "the list's bar stays 3 pt (the palette shares it): \(label)")
        }
    }
}
