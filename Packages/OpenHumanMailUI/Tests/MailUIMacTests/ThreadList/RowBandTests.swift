import AppKit
import MailActions
import MailFeatures
import MailTheme
import Testing
@testable import MailUIMac

@MainActor
@Suite struct RowBandTests {
    static let darkThemes = [BuiltinThemeID.dark, BuiltinThemeID.midnight, BuiltinThemeID.systemDark]

    static func everyTheme() -> [(String, ThemeTokens)] {
        var result: [(String, ThemeTokens)] = []
        for themeID in [BuiltinThemeID.light, BuiltinThemeID.paper, BuiltinThemeID.systemLight] + darkThemes {
            for accent in BuiltinThemeID.accents {
                let t = ThemeLibrary.builtIn.resolve(themeID: themeID, appearance: darkThemes.contains(themeID) ? .dark : .light,
                                                     preferences: ThemePreferences(accentID: accent)).tokens
                result.append(("\(themeID) \(accent)", t))
            }
        }
        return result
    }

    @Test func theCursorFillIsTheBandForPeriwinkleAndFallsBackWhereItWouldNotRead() {
        for theme in [ThemeTokens.light, ThemeTokens.dark] {
            let band = theme.accentSubtle.composited(over: theme.bgWindow)
            #expect(ThreadRowStyle.cursorFill(theme) == band)
            #expect(RenderReviewFixTests.same(ThreadRowStyle(theme: theme).cursor, band.nsColor))
        }
        var synthetic = ThemeTokens.light
        synthetic.component.row.bgCursor = ThemeColor(hex: "#3A3A48")!
        let grey = synthetic.bgRowSelected.composited(over: synthetic.bgWindow)
        #expect(ThreadRowStyle.cursorFill(synthetic) == grey)
        #expect(RenderReviewFixTests.same(ThreadRowStyle(theme: synthetic).cursor, grey.nsColor))
    }

    @Test func theGlyphTintIsTheAccentWhereItReads() {
        for (label, t) in Self.everyTheme() {
            let tint = ThreadRowStyle.glyphTint(t)
            let plates = [ThreadRowStyle.cursorFill(t), t.component.row.bgHover.composited(over: t.bgWindow)]
            if plates.allSatisfy({ t.accentText.contrastRatio(on: $0) >= 3 }) {
                #expect(tint == t.accentText, "\(label)")
            } else {
                #expect(tint == t.textSecondary, "\(label)")
            }
            #expect(RenderReviewFixTests.same(ThreadRowStyle(theme: t).actionTint, tint.nsColor), "\(label)")
        }
    }

    @Test func theHoverGroupIsDoneSnoozeAndRemindMe() {
        #expect(ThreadListViewController(theme: .light).hoverActions == [.markDone, ThreadListActionIDs.snooze, .remind])
    }

    @Test func aButtonAtRestTakesTheGlyphTintAndNoFill() {
        for theme in [ThemeTokens.light, ThemeTokens.dark] {
            let style = ThreadRowStyle(theme: theme)
            let button = RowActionButton(image: NSImage(), style: style)
            #expect(RenderReviewFixTests.same(button.contentTintColor, style.actionTint))
            #expect(button.layer?.backgroundColor == nil)
        }
    }

    @Test func thePlateEdgeShowsOnlyUnderIncreaseContrast() {
        for increase in [false, true] {
            let t = ThemeLibrary.builtIn.resolve(themeID: BuiltinThemeID.light, appearance: .light,
                                                 increaseContrast: increase).tokens
            let view = ThreadRowBackgroundView(style: ThreadRowStyle(theme: t))
            #expect(view.drawsEdge == t.increaseContrast && view.drawsEdge == increase)
        }
    }
}
