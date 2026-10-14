import Foundation
import Testing
@testable import MailTheme

@Suite struct ReaderCSSTests {
    @Test func lightMatchesTheDesignStylesheet() {
        let css = ResolvedTheme.light.readerCSS
        for line in ["color-scheme: light;", "--oh-text: #1a1c20;", "--oh-text-secondary: #5e646e;", "--oh-link: #2272ae;",
                     "--oh-bg: transparent;", "--oh-quote: #8e949c;", "--oh-mark: #fcefc0;", "--oh-sunken: #f3f4f6;",
                     "--oh-font: -apple-system, \"SF Pro Text\", system-ui, sans-serif;", "--oh-size: 14px;", "--oh-lh: 22px;",
                     "--oh-mono-size: 12px;", "--oh-mono-lh: 18px;", "--oh-max-image-width: 100%;"] {
            #expect(css.contains(line), "missing \(line)")
        }
        #expect(css.contains("img { max-width: var(--oh-max-image-width); height: auto; }"))
        #expect(css.contains("border-left: 2px solid var(--oh-quote)"))
        #expect(css.contains("padding-left: 12px"))
        #expect(!css.contains("text-decoration: underline"))
    }

    @Test func darkUsesDarkSchemeAndColors() {
        let css = ResolvedTheme.dark.readerCSS
        #expect(css.contains("color-scheme: dark;"))
        #expect(css.contains("--oh-text: #eceef2;"))
        #expect(css.contains("--oh-link: #7cc0f2;"))
        #expect(ReaderCSS.stylesheet(for: .dark, colorScheme: .lightDark).contains("color-scheme: light dark;"))
    }

    @Test func graphiteUnderlinesLinks() {
        let graphite = ThemeLibrary.builtIn.resolve(ThemePreferences(accentID: "graphite"), appearance: .light)
        #expect(graphite.readerCSS.contains("a { color: var(--oh-link); text-decoration: underline; }"))
    }

    @Test func readerPreferencesReachTheStylesheet() {
        let resolved = ThemeLibrary.builtIn.resolve(ThemePreferences(readerTextSize: 18, readerFont: .named("Source Serif 4")), appearance: .light)
        #expect(resolved.readerCSS.contains("--oh-size: 18px;"))
        #expect(resolved.readerCSS.contains("--oh-lh: 28px;"))
        #expect(resolved.readerCSS.contains("--oh-font: \"Source Serif 4\", -apple-system"))
    }

    @Test func fontNamesAreEscapedCSSStrings() {
        #expect(ReaderCSS.cssString("Inter") == "\"Inter\"")
        #expect(ReaderCSS.cssString("a\"b;c") == "\"a\\000022 b\\00003B c\"")
        #expect(ReaderCSS.fontStack(.systemSerif, role: .reader).hasPrefix("ui-serif"))
    }

    @Test func colorsSerializeFromTypedValues() throws {
        #expect(try #require(ThemeColor(literal: "rgba(17,20,26,0.06)")).css == "rgba(17,20,26,0.060)")
        #expect(ThemeTokens.light.shadow1.css == "0 1px 2px 0 rgba(17,20,26,0.060), 0 4px 12px 0 rgba(17,20,26,0.060)")
    }

    @Test func liveReplaceScriptCannotBeBrokenOutOf() {
        let script = ReaderCSS.replaceScript(css: "a{}\"); alert(1); (\"</script>")
        #expect(script.hasPrefix("(function(){var s=document.getElementById(\"oh-base\");if(s){s.textContent=\""))
        #expect(script.contains("\\\"); alert(1); (\\\""))
        #expect(script.hasSuffix(";}})();"))
    }

    @Test func variablesComeFromTheRegistry() {
        let names = ReaderCSS.variables(tokens: .light).map(\.name)
        for variable in ReaderCSSVariables.tokens.map(\.variable) { #expect(names.contains(variable)) }
        #expect(Set(names).count == names.count)
    }
}

@Suite struct ThemeDocsExampleTests {
    @Test func docsExamplesValidateWithoutIssues() throws {
        let text = try Repo.text(Repo.root.appendingPathComponent("docs/themes.md"))
        let blocks = text.components(separatedBy: "```json\n").dropFirst().compactMap { $0.components(separatedBy: "```").first }
        #expect(blocks.count == 2)
        var library = ThemeLibrary.builtIn
        for block in blocks {
            let result = ThemeValidator.validate(data: Data(block.utf8))
            #expect(result.issues.isEmpty, "\(result.issues)")
            let summary = library.add(result, source: .user(URL(fileURLWithPath: "/tmp/doc-\(result.file?.id ?? "x").json")))
            #expect(summary.isUsable && summary.issues.isEmpty, "\(summary.issues)")
        }
        let solar = library.resolve(ThemePreferences(lightThemeID: "me.solar", accentID: "sunset"), appearance: .light)
        #expect(solar.themeID == "me.solar" && solar.accentID == "sunset")
    }
}
