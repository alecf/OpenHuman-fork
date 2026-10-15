import Testing
@testable import MailTheme

@Suite struct ListRowFillsTests {
    static let checkedApartFromCursor = 10.0

    private static func resolve(_ themeID: String, accent: String, increase: Bool = false) -> ThemeTokens {
        let appearance: ThemeAppearance = LabelChipContrastTests.darkThemes.contains(themeID) ? .dark : .light
        return ThemeLibrary.builtIn.resolve(themeID: themeID, appearance: appearance,
                                            preferences: ThemePreferences(accentID: accent), increaseContrast: increase).tokens
    }

    @Test func periwinkleGetsTheAccentBandInLightAndDark() {
        for themeID in [BuiltinThemeID.light, BuiltinThemeID.dark] {
            let t = Self.resolve(themeID, accent: "periwinkle")
            #expect(t.listCursorFill == t.accentSubtle.composited(over: t.bgWindow), "\(themeID)")
            #expect(t.listCursorFill != t.bgRowSelected.composited(over: t.bgWindow), "\(themeID)")
        }
    }

    @Test func aBandThatDoesNotReadFallsBackToTheSelectedPlate() {
        var t = ThemeTokens.light
        t.component.row.bgCursor = ThemeColor(hex: "#3A3A48")!
        #expect(t.listCursorFill == t.bgRowSelected.composited(over: t.bgWindow))
        #expect(!t.listCursorFillReads(t.component.row.bgCursor))
        var same = ThemeTokens.light
        same.component.row.bgCursor = same.component.row.bgHover.composited(over: same.bgWindow)
        #expect(same.listCursorFill == same.bgRowSelected.composited(over: same.bgWindow))
    }

    @Test func checkedRowsGetTheThemesOwnTintApartFromTheCursorEverywhere() {
        for (label, t) in LabelChipContrastTests.everyResolvedTheme() {
            let fill = t.listCheckedFill
            #expect(fill == t.component.row.bgChecked.composited(over: t.bgWindow), "the theme's checked tint: \(label)")
            #expect(fill != t.listCursorFill, "\(label)")
            #expect(ThemeTokens.standApart(t.listCursorFill, fill, luminance: 1.06), "checked vs cursor: \(label)")
            #expect(t.listCursorFill.perceptualDifference(from: fill) >= Self.checkedApartFromCursor,
                    "checked vs cursor, not two shades of one tint: \(label)")
            #expect(t.listCursorFillReads(fill), "text, bar, hover and chips on the checked plate: \(label)")
            #expect(t.textSecondary.contrastRatio(on: fill) >= 4.5, "snippet, read dates and counts on a checked row: \(label)")
        }
        for themeID in [BuiltinThemeID.light, BuiltinThemeID.dark] {
            let t = Self.resolve(themeID, accent: "periwinkle")
            #expect(t.component.row.bgChecked != t.accentSubtle, "\(themeID)")
        }
    }

    @Test func aCheckedTintThatMatchesTheCursorFallsBackToOneThatStandsApart() {
        for base in [ThemeTokens.light, ThemeTokens.dark] {
            var t = base
            t.component.row.bgChecked = t.component.row.bgCursor
            #expect(!t.listCheckedFillReads(t.component.row.bgChecked))
            #expect(t.listCheckedFill != t.listCursorFill)
            #expect(t.listCheckedFillReads(t.listCheckedFill))
        }
    }

    @Test func blueAccentsKeepTheCheckedRowOffTheCursorsBlue() {
        let blue: [(String, String)] = [
            (BuiltinThemeID.systemLight, "system"), (BuiltinThemeID.systemDark, "system"), (BuiltinThemeID.light, "blue"),
            (BuiltinThemeID.dark, "blue"), (BuiltinThemeID.light, "system"), (BuiltinThemeID.paper, "blue"),
        ]
        for (themeID, accent) in blue {
            for increase in [false, true] {
                let t = Self.resolve(themeID, accent: accent, increase: increase)
                let label = "\(themeID) \(accent) increaseContrast=\(increase)"
                #expect(t.listCursorFill == t.accentSubtle.composited(over: t.bgWindow), "the cursor is the blue band: \(label)")
                #expect(t.listCheckedFill == t.component.row.bgChecked.composited(over: t.bgWindow), "\(label)")
                #expect(t.listCursorFill.perceptualDifference(from: t.listCheckedFill) >= Self.checkedApartFromCursor, "\(label)")
            }
        }
        #expect(ThemeLibrary.builtIn.resolve(themeID: BuiltinThemeID.systemLight, appearance: .light).accentID == "system")
        #expect(ThemeLibrary.builtIn.resolve(themeID: BuiltinThemeID.systemDark, appearance: .dark).accentID == "system")
    }

    @Test func lightHoverIsAVisibleStepOffTheWindow() {
        let t = Self.resolve(BuiltinThemeID.light, accent: "periwinkle")
        #expect(t.component.row.bgHover.composited(over: t.bgWindow).contrastRatio(on: t.bgWindow) >= 1.08)
    }

    @Test func theDrawnFillReadsEverywhereAndIsTheBandAlmostEverywhere() {
        let fallsBack: Set<String> = [
            "\(BuiltinThemeID.dark) graphite increaseContrast=false", "\(BuiltinThemeID.dark) graphite increaseContrast=true",
            "\(BuiltinThemeID.systemLight) graphite increaseContrast=false",
            "\(BuiltinThemeID.systemLight) graphite increaseContrast=true",
            "\(BuiltinThemeID.midnight) graphite increaseContrast=false",
        ]
        for (label, t) in LabelChipContrastTests.everyResolvedTheme() {
            let fill = t.listCursorFill, row = t.component.row
            let band = row.bgCursor.composited(over: t.bgWindow)
            #expect((fill == band) == !fallsBack.contains(label), "band or grey plate: \(label)")
            #expect(t.textPrimary.contrastRatio(on: fill) >= 4.5, "text.primary: \(label)")
            #expect(t.textSecondary.contrastRatio(on: fill) >= 4.5, "text.secondary, also the snippet, read dates and counts: \(label)")
            #expect(row.dateUnread.contrastRatio(on: fill) >= 4.5, "row.dateUnread: \(label)")
            #expect(t.textTertiary.contrastRatio(on: fill) >= 3, "tertiary glyphs: \(label)")
            #expect(row.cursorBar.contrastRatio(on: fill) >= 3, "the bar: \(label)")
            #expect(ThemeTokens.standApart(row.bgHover.composited(over: t.bgWindow), fill, luminance: 1.06), "hover: \(label)")
            #expect(ThemeTokens.standApart(row.chipBg, fill, luminance: t.increaseContrast ? 1.4 : 1.1), "chip: \(label)")
        }
    }

    @Test func actionGlyphsReadOnEveryPlate() {
        for (label, t) in LabelChipContrastTests.everyResolvedTheme() {
            let plates = [t.listCursorFill, t.component.row.bgHover.composited(over: t.bgWindow)]
            let rest = t.listActionTint
            #expect(rest == t.accentText || rest == t.textSecondary, "\(label)")
            if t.accentText.contrastRatio(on: plates[0]) >= 3, t.accentText.contrastRatio(on: plates[1]) >= 3 {
                #expect(rest == t.accentText, "accent.text where it reads: \(label)")
            }
            #expect(t.listActionPointerFill.alpha == 0.08 && t.listActionPressedFill.alpha == 0.14, "\(label)")
            for plate in plates {
                #expect(rest.contrastRatio(on: plate) >= 3, "at rest: \(label)")
                for fill in [t.listActionPointerFill, t.listActionPressedFill] {
                    #expect(t.listActionTintUnderPointer.contrastRatio(on: fill.composited(over: plate)) >= 3,
                            "under the pointer: \(label)")
                }
            }
        }
        let light = Self.resolve(BuiltinThemeID.light, accent: "periwinkle")
        #expect(light.listActionTint == light.accentText && light.listActionTintUnderPointer == light.accentFillHover)
    }

    @Test func perceptualDifferenceIsCIE76() {
        let white = ThemeColor(hex: "#FFFFFF")!, black = ThemeColor(hex: "#000000")!
        #expect(abs(white.perceptualDifference(from: black) - 100) < 0.01)
        #expect(white.perceptualDifference(from: white) == 0)
        let band = ThemeColor(hex: "#ECEDF8")!, hover = ThemeColor(hex: "#F7F7F7")!
        #expect(band.perceptualDifference(from: hover) > 5 && band.perceptualDifference(from: hover) < 7)
    }
}
