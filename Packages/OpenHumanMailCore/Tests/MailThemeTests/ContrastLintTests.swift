import Foundation
import Testing
@testable import MailTheme

@Suite struct ContrastLintTests {
    @Test func wcagRatiosMatchKnownValues() throws {
        let black = try #require(ThemeColor(hex: "#000000"))
        let white = try #require(ThemeColor(hex: "#FFFFFF"))
        #expect(abs(black.contrastRatio(on: white) - 21) < 0.0001)
        #expect(abs(white.contrastRatio(on: white) - 1) < 0.0001)
        #expect(abs(try #require(ThemeColor(hex: "#1A1C20")).contrastRatio(on: white) - 17.06) < 0.005)
        let halfBlack = try #require(ThemeColor(literal: "rgba(0,0,0,0.5)"))
        #expect(halfBlack.contrastRatio(on: white) < black.contrastRatio(on: white))
    }

    @Test func designTableIsReproducedForEveryThemeAndAccent() throws {
        let spec = try Repo.text(Repo.designSpec)
        let library = ThemeLibrary.builtIn
        var compared = 0
        for (heading, themeID, appearance) in [("#### light", BuiltinThemeID.light, ThemeAppearance.light),
                                               ("#### dark", BuiltinThemeID.dark, .dark),
                                               ("#### paper", BuiltinThemeID.paper, .light),
                                               ("#### midnight", BuiltinThemeID.midnight, .dark)] {
            let rows = markdownTable(in: spec, after: heading)
            #expect(rows.count == 71, "\(heading)")
            var computed: [String: ContrastCheck] = [:]
            for accent in BuiltinThemeID.accents {
                let resolved = library.resolve(themeID: themeID, appearance: appearance, preferences: ThemePreferences(accentID: accent))
                for check in ContrastLint.checks(for: resolved.tokens, accentID: accent) { computed[check.label] = check }
            }
            for row in rows {
                let label = row[0]
                guard let check = computed[label] else {
                    Issue.record("\(heading): no lint pair for \(label)")
                    continue
                }
                let expectedRatio = try #require(Double(row[1].replacingOccurrences(of: ":1", with: "")))
                #expect(check.roundedRatio == expectedRatio, "\(heading) \(label): \(check.ratio) vs \(expectedRatio)")
                #expect(check.required == Double(row[2]), "\(heading) \(label)")
                #expect(check.passes && row[3] == "PASS", "\(heading) \(label)")
                compared += 1
            }
        }
        #expect(compared == 284)
    }

    @Test func builtInsHaveNoLintIssues() {
        for tokens in [ThemeTokens.light, .dark, .paper, .midnight] {
            #expect(ContrastLint.issues(for: tokens).isEmpty)
        }
    }

    @Test func lowContrastThemeLoadsWithWarning() throws {
        let object = userTheme(id: "me.washed", extra: ["semantic": ["color": ["text.secondary": "#B0B4BA"]]])
        var library = ThemeLibrary.builtIn
        let summary = library.add(data: themeJSON(object), source: .user(URL(fileURLWithPath: "/tmp/washed.json")))
        #expect(summary.isUsable)
        let warnings = summary.issues.filter { $0.code == .contrast }
        #expect(!warnings.isEmpty)
        #expect(warnings.contains { $0.path == "semantic.color.text.secondary" && $0.message.contains("needs 4.5:1") })
        #expect(summary.issueLines.contains { $0.hasPrefix("washed.json: semantic.color.text.secondary: ") && $0.hasSuffix("loaded with warning") })
        let resolved = library.resolve(ThemePreferences(lightThemeID: "me.washed"), appearance: .light)
        #expect(resolved.themeID == "me.washed")
        #expect(resolved.issues.contains { $0.code == .contrast })
    }

    @Test func unreadablePrimaryTextIsRefused() throws {
        let object = userTheme(id: "me.ghost", extra: ["semantic": ["color": ["text.primary": "#DDDDDD"]]])
        var library = ThemeLibrary.builtIn
        let summary = library.add(data: themeJSON(object), source: .user(URL(fileURLWithPath: "/tmp/ghost.json")))
        #expect(!summary.isUsable)
        #expect(summary.issues.contains { $0.code == .contrastRefused && $0.severity == .refused })
        let resolved = library.resolve(ThemePreferences(lightThemeID: "me.ghost"), appearance: .light)
        #expect(resolved.themeID == BuiltinThemeID.light)
        #expect(resolved.issues.contains { $0.code == .themeUnavailable })
    }

    @Test func lintFailsForABadTable() {
        var tokens = ThemeTokens.light
        tokens.textTertiary = ThemeColor(r8: 0xC0, g8: 0xC0, b8: 0xC0)
        tokens.accentRing = ThemeColor(r8: 0xF0, g8: 0xF0, b8: 0xF0)
        let failing = ContrastLint.checks(for: tokens, accentID: "blue").filter { !$0.passes }.map(\.label)
        #expect(failing.contains("text.tertiary on bg.window"))
        #expect(failing.contains("[blue] focus.ring on bg.window (non-text)"))
        #expect(!ContrastLint.issues(for: tokens).isRefused)
    }
}
