import Foundation
import MailModel
import MailTheme
import Testing
@testable import MailRender

private func color(_ css: String) -> CSSColorValue? {
    CSSSanitizer.parseComponents(CSSTokenizer.tokenize(css)).first.flatMap(CSSColor.value(of:))
}

private func hex(_ value: CSSColorValue?) -> String? {
    if case .color(let c)? = value { return c.css }
    return nil
}

@Test func cssColorsParse() {
    #expect(hex(color("#fff")) == "#ffffff")
    #expect(hex(color("#ABCDEF")) == "#abcdef")
    #expect(hex(color("#0008")) == "rgba(0,0,0,0.533)")
    #expect(hex(color("#11223380")) == "rgba(17,34,51,0.502)")
    #expect(hex(color("RebeccaPurple")) == "#663399")
    #expect(hex(color("rgb(255, 0, 0)")) == "#ff0000")
    #expect(hex(color("rgba(0,0,255,.5)")) == "rgba(0,0,255,0.500)")
    #expect(hex(color("rgb(0 128 0 / 50%)")) == "rgba(0,128,0,0.500)")
    #expect(hex(color("rgb(100%, 50%, 0%)")) == "#ff8000")
    #expect(hex(color("hsl(120, 100%, 25%)")) == "#008000")
    #expect(hex(color("hsl(0.5turn 100% 50%)")) == "#00ffff")
    #expect(hex(color("windowtext")) == "#000000")
    #expect(color("transparent") == .transparent)
    #expect(color("currentColor") == .inherited)
    #expect(color("var(--x)") == .unknown)
    #expect(color("lab(50% 40 59)") == .unknown)
    #expect(color("Highlight") == .unknown)
    #expect(color("bold") == nil)
    #expect(color("#12345") == .unknown)
}

@Test func legacyAttributeColorsFollowTheHTMLAlgorithm() {
    func legacy(_ s: String) -> String? { if case .color(let c) = CSSColor.parseLegacyAttribute(s) { return c.css }; return nil }
    #expect(legacy("chucknorris") == "#c00000")
    #expect(legacy("ffffff") == "#ffffff")
    #expect(legacy("#FFF") == "#ffffff")
    #expect(legacy("fff") == "#0f0f0f")
    #expect(legacy("navy") == "#000080")
    #expect(legacy(" #00ff00 ") == "#00ff00")
    #expect(CSSColor.parseLegacyAttribute("transparent") == .transparent)
    #expect(CSSColor.parseLegacyAttribute("") == .unknown)
}

@Test func oklchMatchesReferenceValues() {
    let red = OKLCH(ThemeColor(r8: 255, g8: 0, b8: 0))
    #expect(abs(red.l - 0.62796) < 0.0005 && abs(red.c - 0.25768) < 0.0005 && abs(red.h - 29.23) < 0.05)
    let white = OKLCH(ThemeColor(r8: 255, g8: 255, b8: 255))
    #expect(abs(white.l - 1) < 0.0005 && white.c < 0.0005)
    let black = OKLCH(ThemeColor(r8: 0, g8: 0, b8: 0))
    #expect(black.l < 0.0005)
}

@Test func oklchRoundTripsEveryByte() {
    var generator = SplitMix64(seed: 7)
    for _ in 0..<2_000 {
        let c = ThemeColor(r8: UInt8(generator.next() % 256), g8: UInt8(generator.next() % 256), b8: UInt8(generator.next() % 256))
        let back = ColorRemapper.quantized(OKLCH(c).srgb)
        #expect(back.css == c.css, "\(c.css) -> \(back.css)")
    }
}

@Test func cieLightnessThresholds() {
    #expect(ThemeColor(r8: 0x1F, g8: 0x1F, b8: 0x1F).cieLightness < 30)
    #expect(ThemeColor(r8: 0x48, g8: 0x48, b8: 0x48).cieLightness > 30)
    #expect(abs(ThemeColor(r8: 255, g8: 255, b8: 255).cieLightness - 100) < 0.01)
}

@Test func remapFollowsTheDesignFormula() {
    #expect(ColorRemapper.remap(ThemeColor(r8: 255, g8: 255, b8: 255), role: .background).css == "#000000")
    #expect(ColorRemapper.remap(ThemeColor(r8: 0, g8: 0, b8: 0), role: .text).css == "#ffffff")
    let midBackground = ThemeColor(r8: 0x30, g8: 0x56, b8: 0xD3)
    #expect(ColorRemapper.remap(midBackground, role: .background) == midBackground)
    let lightText = ThemeColor(r8: 0xEE, g8: 0xEE, b8: 0xEE)
    #expect(ColorRemapper.remap(lightText, role: .text) == lightText)
    let brand = ThemeColor(r8: 0xE5, g8: 0x73, b8: 0x73)
    let before = OKLCH(brand), after = OKLCH(ColorRemapper.remap(brand, role: .background))
    #expect(abs(after.l - (1 - before.l)) < 0.01)
    #expect(abs(after.h - before.h) < 3)
    #expect(after.c <= before.c * 0.9 + 0.005)
}

@Test func nudgeReachesFourPointFiveForRandomPairs() {
    var generator = SplitMix64(seed: 45)
    func random() -> ThemeColor { ThemeColor(r8: UInt8(generator.next() % 256), g8: UInt8(generator.next() % 256), b8: UInt8(generator.next() % 256)) }
    for _ in 0..<3_000 {
        let text = random(), background = random()
        let nudged = ColorRemapper.nudged(text: text, on: background)
        let ratio = nudged.contrastRatio(on: background)
        #expect(ratio >= 4.5, "\(text.css) on \(background.css) -> \(nudged.css) \(ratio)")
        if text.contrastRatio(on: background) >= 4.5 { #expect(nudged == text) }
    }
}

@Test func nudgeKeepsHueWhereItCan() {
    let blue = ThemeColor(r8: 0x1A, g8: 0x73, b8: 0xE8)
    let onDark = ColorRemapper.nudged(text: blue, on: ThemeColor(r8: 0x3A, g8: 0x3A, b8: 0x3A))
    #expect(abs(OKLCH(onDark).h - OKLCH(blue).h) < 8)
    #expect(OKLCH(onDark).l > OKLCH(blue).l)
}

private func tier(_ html: String) -> DarkModeTier { HTMLSanitizer.sanitize(html).tier }

@Test func plainMessagesAreTierA() {
    #expect(tier("<p>Hello</p>") == .plain)
    #expect(tier("<div style=\"color:#000;background:#fff\"><font color=\"black\">x</font></div>") == .plain)
    #expect(tier("<p style=\"color:#666\">gray</p><td bgcolor=\"#FEFEFE\">x</td>") == .plain)
    #expect(tier("<p style=\"color:rgba(0,0,0,.87)\">material</p>") == .plain)
    #expect(tier("<style>a:link,span.MsoHyperlink{color:#0563C1} span.x{color:windowtext}</style><p>x</p>") == .plain)
    #expect(tier("<a href=\"https://example.com\" style=\"color:#1155cc\">link</a>") == .plain)
    #expect(tier("<div style=\"border:1px solid #c00\">borders do not count</div>") == .plain)
}

@Test func selfAdaptingMessagesAreTierB() {
    #expect(tier("<meta name=\"color-scheme\" content=\"light dark\"><p style=\"color:#c00\">x</p>") == .selfAdapting)
    #expect(tier("<meta name=\"supported-color-schemes\" content=\"light, dark\"><p>x</p>") == .selfAdapting)
    #expect(tier("<style>@media (prefers-color-scheme: dark) { p { color: #fff } }</style><p style=\"background:#123\">x</p>") == .selfAdapting)
    #expect(tier("<meta name=\"color-scheme\" content=\"light\"><p>x</p>") == .plain)
    #expect(tier("<style>@media (prefers-color-scheme: light) { p { color: red } }</style>") == .designed)
}

@Test func designedMessagesAreTierC() {
    #expect(tier("<p style=\"color:#d0021b\">brand red</p>") == .designed)
    #expect(tier("<p style=\"color:#ffffff\">white text</p>") == .designed)
    #expect(tier("<div style=\"background:#f5f5f5\">panel</div>") == .designed)
    #expect(tier("<div style=\"background-image:linear-gradient(#fff,#eee)\">x</div>") == .designed)
    #expect(tier("<table background=\"cid:bg\"><tr><td>x</td></tr></table>") == .designed)
    #expect(tier("<table><tr><td bgcolor=\"#e8f0fe\">x</td></tr></table>") == .designed)
    #expect(tier("<p style=\"color:var(--ink)\">x</p>") == .designed)
    #expect(tier("<body bgcolor=\"#000\"><p>x</p></body>") == .designed)
    #expect(tier("<style>.x{background:#fffbea}</style><p class=x>x</p>") == .designed)
}

@Test func droppedMarkupDoesNotCountTowardTheTier() {
    #expect(tier("<p>x</p><svg><rect style=\"fill:#f00\"/></svg><script>var c='#f00'</script>") == .plain)
}

@Test func treatmentPolicyTable() {
    func t(_ tier: DarkModeTier, _ a: ThemeAppearance, _ e: EmailColors, _ o: ColorOverride? = nil) -> ColorTreatment {
        DarkModePolicy.treatment(tier: tier, appearance: a, emailColors: e, override: o)
    }
    for a in ThemeAppearance.allCases {
        #expect(t(.plain, a, .adaptWhenSafe) == .themeText)
        #expect(t(.selfAdapting, a, .adaptWhenSafe) == .selfAdapting)
        #expect(t(.designed, a, .adaptWhenSafe) == .original)
        for tier in DarkModeTier.allCases { #expect(t(tier, a, .alwaysOriginal) == .original) }
        for tier in DarkModeTier.allCases { #expect(t(tier, a, .alwaysAdapt, .originalColors) == .original) }
    }
    #expect(t(.designed, .dark, .alwaysAdapt) == .remapped)
    #expect(t(.designed, .light, .alwaysAdapt) == .original)
    #expect(t(.designed, .dark, .adaptWhenSafe, .darkColors) == .remapped)
    #expect(t(.designed, .light, .adaptWhenSafe, .darkColors) == .original)
    #expect(t(.plain, .dark, .alwaysOriginal, .darkColors) == .themeText)
    #expect(DarkModePolicy.colorScheme(for: .selfAdapting, appearance: .light) == .lightDark)
    #expect(DarkModePolicy.colorScheme(for: .original, appearance: .dark) == .dark)
    #expect(DarkModePolicy.colorScheme(for: .remapped, appearance: .dark) == .dark)
}

private func render(_ html: String, _ appearance: ThemeAppearance, _ emailColors: EmailColors = .adaptWhenSafe,
                    override: ColorOverride? = nil) -> SanitizedHTML {
    let theme: ThemeTokens = appearance == .dark ? .dark : .light
    return HTMLSanitizer.sanitize(html, colors: ColorContext(theme: theme, appearance: appearance, emailColors: emailColors,
                                                             override: override))
}

@Test func tierARewritesToThemeVariables() {
    let s = render("<div style=\"color:#111;background:#fff\"><font color=\"#000000\">a</font><span style=\"color:#777\">b</span>"
        + "<a href=\"https://e.example\" style=\"color:#1155cc\">c</a></div><table bgcolor=\"white\"><tr><td>d</td></tr></table>", .dark)
    #expect(s.treatment == .themeText)
    #expect(s.bodyHTML == "<div style=\"color:var(--oh-text);background:transparent\"><font style=\"color:var(--oh-text)\">a</font>"
        + "<span style=\"color:var(--oh-text-secondary)\">b</span><a href=\"https://e.example\" style=\"color:var(--oh-link)\" "
        + "rel=\"noopener noreferrer\">c</a></div><table><tbody><tr><td>d</td></tr></tbody></table>")
}

@Test func tierAAppliesInLightThemesToo() {
    let s = render("<p style=\"color:#000\">x</p>", .light)
    #expect(s.bodyHTML == "<p style=\"color:var(--oh-text)\">x</p>")
}

@Test func tierCKeepsOriginalColorsUnlessRemapped() {
    let html = "<div style=\"background:#ffffff;color:#222\"><p style=\"color:#d0021b\">x</p></div>"
    #expect(render(html, .dark).bodyHTML == HTMLSanitizer.sanitize(html).bodyHTML)
    let remapped = render(html, .dark, override: .darkColors)
    #expect(remapped.treatment == .remapped)
    #expect(remapped.bodyHTML.contains("background:#000000"))
    #expect(!remapped.bodyHTML.contains("invert") && !remapped.bodyHTML.contains("hue-rotate"))
    #expect(render(html, .dark, .alwaysAdapt).treatment == .remapped)
}

@Test func remapNeverTouchesImagesOrNonColorProperties() {
    let s = render("<div style=\"font-family: Gold, Navy, serif; background-image: url(cid:x); background: #fff url(cid:y); border: 1px solid black\">t</div>",
                   .dark, override: .darkColors)
    #expect(s.bodyHTML.contains("font-family:Gold, Navy, serif"))
    #expect(s.bodyHTML.contains("background-image:url(&quot;ohcid:x&quot;)"))
    #expect(s.bodyHTML.contains("background:#000000 url(&quot;ohcid:y&quot;)"))
    #expect(s.bodyHTML.contains("border:1px solid #ffffff"))
}

@Test func remapNudgesResolvablePairs() {
    let s = render("<div style=\"background:#777\"><p style=\"color:#888\">low</p></div>", .dark, override: .darkColors)
    #expect(s.bodyHTML.contains("color:#") && s.bodyHTML.contains("!important"))
    #expect(!s.bodyHTML.contains("color:#888888"), "the low-contrast color is replaced, not duplicated: \(s.bodyHTML)")
}

@Test func emailColorSchemeIsDroppedOutsideTierB() {
    #expect(!render("<style>p{color-scheme:dark}</style><p style=\"color-scheme:dark;color:#c00\">x</p>", .dark).headCSS.joined().contains("color-scheme"))
    let b = render("<meta name=color-scheme content=\"light dark\"><style>p{color-scheme:light dark}</style>", .dark)
    #expect(b.headCSS.joined().contains("color-scheme"))
}

@Test func linkOnlySelectors() {
    func tokens(_ s: String) -> [CSSToken] { CSSTokenizer.tokenize(s) }
    #expect(ColorTransform.isLinkOnly(tokens(".oh-body a:link,.oh-body span.MsoHyperlink")))
    #expect(ColorTransform.isLinkOnly(tokens(".oh-body a:visited")))
    #expect(!ColorTransform.isLinkOnly(tokens(".oh-body a.button")))
    #expect(!ColorTransform.isLinkOnly(tokens(".oh-body p a")))
    #expect(!ColorTransform.isLinkOnly(tokens(".oh-body span")))
}

@Test func documentShowsTheCardInDarkAndThePaperInLight() throws {
    let html = "<body bgcolor=\"#fffbea\"><p style=\"color:#3d2c00\">x</p></body>"
    guard case .html(let dark) = MessageRenderer(theme: .dark, appearance: .dark).render(MessageContent(html: html, text: nil)),
          case .html(let light) = MessageRenderer(theme: .light, appearance: .light).render(MessageContent(html: html, text: nil)) else {
        Issue.record("expected html"); return
    }
    #expect(dark.html.contains("<div class=\"oh-body oh-original oh-card\">"))
    #expect(dark.html.contains(":where(.oh-original) { color-scheme: light; color: CanvasText;"))
    #expect(dark.colorScheme == .dark)
    #expect(light.html.contains("<div class=\"oh-body oh-original oh-paper\">"))
    #expect(dark.html.contains("<style id=\"oh-body-attributes\">.oh-body{background-color:#fffbea}</style>"))
}

@Test func renderedMessagesNeverContainInvertOrHueRotate() {
    for fixture in EmailFixture.all {
        for variant in RenderVariant.all {
            guard let r = variant.render(fixture.html) else { continue }
            #expect(!r.html.contains("invert(") && !r.html.contains("hue-rotate("), "\(fixture.name) \(variant.testDescription)")
        }
    }
}

@Test func remapResolvesAgainstTheCardInEveryDarkTheme() throws {
    let themes: [(String, ThemeTokens)] = [
        ("dark", .dark), ("midnight", .midnight),
        ("system dark", ThemeLibrary.builtIn.resolve(themeID: BuiltinThemeID.systemDark, appearance: .dark).tokens),
    ]
    for (name, theme) in themes {
        let colors = ColorContext(theme: theme, appearance: .dark, emailColors: .adaptWhenSafe, override: .darkColors)
        #expect(colors.canvas == theme.bgCard, "\(name): the context canvas is bg.card")
        let s = HTMLSanitizer.sanitize("<table><tr><td style=\"color:#a00000\">brand</td></tr></table>",
                                       colors: colors)
        let css = try #require(s.bodyHTML.components(separatedBy: "color:#").last?.prefix(6))
        guard case .color(let text)? = color("#" + css) else { Issue.record("\(name): no color in \(s.bodyHTML)"); continue }
        #expect(text.contrastRatio(on: theme.bgCard) >= 4.5, "\(name): \(css) on bg.card in \(s.bodyHTML)")
        for sample in [ThemeColor(r8: 0x88, g8: 0x88, b8: 0x88), ThemeColor(r8: 0x1A, g8: 0x73, b8: 0xE8),
                       ThemeColor(r8: 0xF7, g8: 0x40, b8: 0x3E), ThemeColor(r8: 0x30, g8: 0x30, b8: 0x30)] {
            let n = ColorRemapper.nudged(text: sample, on: theme.bgCard)
            #expect(n.contrastRatio(on: theme.bgCard) >= 4.5, "\(name): nudged \(sample.css)")
        }
    }
}
