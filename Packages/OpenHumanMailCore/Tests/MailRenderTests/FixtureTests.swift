import Foundation
import MailModel
import MailTheme
import Testing
@testable import MailRender

struct EmailFixture: CustomTestStringConvertible, Sendable {
    let name: String
    let html: String
    let tier: DarkModeTier
    let quoted: Bool
    let links: Int?
    let trackers: Int?
    let inline: Int?
    var testDescription: String { name }

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/emails")

    static let all: [EmailFixture] = {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "html" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap(load)
    }()

    static func load(_ url: URL) -> EmailFixture? {
        guard let html = try? String(contentsOf: url, encoding: .utf8),
              let header = html.components(separatedBy: "\n").first, header.hasPrefix("<!-- fixture:") else { return nil }
        var fields: [String: String] = [:]
        for pair in header.split(separator: " ") where pair.contains("=") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[kv[0]] = kv[1]
        }
        guard let tier = fields["tier"].flatMap(DarkModeTier.init(rawValue:)) else { return nil }
        return EmailFixture(name: url.deletingPathExtension().lastPathComponent, html: html, tier: tier,
                            quoted: fields["quoted"] == "yes", links: fields["links"].flatMap(Int.init),
                            trackers: fields["trackers"].flatMap(Int.init), inline: fields["inline"].flatMap(Int.init))
    }
}

@Test func fixtureCorpusIsComplete() {
    let fixtures = EmailFixture.all
    #expect(fixtures.count >= 40, "found \(fixtures.count) fixtures in \(EmailFixture.directory.path)")
    #expect(Set(fixtures.map(\.tier)) == Set(DarkModeTier.allCases))
}

@Test(arguments: EmailFixture.all, RenderVariant.all)
func fixtureRendersSafelyInEveryVariant(_ fixture: EmailFixture, _ variant: RenderVariant) throws {
    let rendered = try #require(variant.render(fixture.html))
    let problems = try SafetyInvariants.violations(in: rendered.html, allowRemote: variant.allowRemote)
    #expect(problems.isEmpty, "\(fixture.name) [\(variant.testDescription)]: \(problems)")
    #expect(rendered.tier == fixture.tier, "\(fixture.name): tier \(rendered.tier)")
    #expect(rendered.hasQuotedText == fixture.quoted, "\(fixture.name): quoted \(rendered.hasQuotedText)")
    if let links = fixture.links { #expect(rendered.suspiciousLinks.count == links, "\(rendered.suspiciousLinks)") }
    if let trackers = fixture.trackers { #expect(rendered.trackerCount == trackers) }
    if let inline = fixture.inline { #expect(rendered.inlineContentIDs.count == inline) }

    let expected: ColorTreatment
    switch (fixture.tier, variant.override) {
    case (.plain, _): expected = .themeText
    case (.selfAdapting, _): expected = .selfAdapting
    case (.designed, .darkColors?): expected = .remapped
    case (.designed, _): expected = .original
    }
    #expect(rendered.colorTreatment == expected)
    if expected == .remapped {
        let failures = try ContrastAudit.failures(in: rendered.html, theme: variant.theme)
        #expect(failures.isEmpty, "\(fixture.name): pairs under 4.5:1 after the remap: \(failures)")
    }
}

@Test(arguments: EmailFixture.all)
func fixtureMatchesGolden(_ fixture: EmailFixture) throws {
    let actual = goldenText(for: fixture)
    let url = EmailFixture.directory.appendingPathComponent("golden/\(fixture.name).txt")
    if ProcessInfo.processInfo.environment["OH_UPDATE_GOLDENS"] == "1" {
        try actual.write(to: url, atomically: true, encoding: .utf8)
        return
    }
    let expected = try String(contentsOf: url, encoding: .utf8)
    if expected != actual {
        let e = expected.components(separatedBy: "\n"), a = actual.components(separatedBy: "\n")
        let line = zip(e, a).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(e.count, a.count)
        Issue.record("""
            \(fixture.name) differs from golden/\(fixture.name).txt at line \(line + 1):
              golden: \(line < e.count ? String(e[line].prefix(300)) : "<end>")
              actual: \(line < a.count ? String(a[line].prefix(300)) : "<end>")
            Regenerate with OH_UPDATE_GOLDENS=1 if the change is intended.
            """)
    }
}

func goldenText(for fixture: EmailFixture) -> String {
    var out = "fixture: \(fixture.name)\n"
    for (label, appearance, override) in [("light", ThemeAppearance.light, ColorOverride?.none), ("dark", .dark, nil),
                                          ("dark, Show in dark colors", .dark, .darkColors)] {
        let theme: ThemeTokens = appearance == .dark ? .dark : .light
        let colors = ColorContext(theme: theme, appearance: appearance, emailColors: .adaptWhenSafe, override: override)
        let s = HTMLSanitizer.sanitize(fixture.html, options: SanitizerOptions(), colors: colors)
        out += "\n=== \(label): tier \(s.tier.rawValue), treatment \(s.treatment.rawValue), "
        out += "scheme \(DarkModePolicy.colorScheme(for: s.treatment, appearance: appearance).rawValue)\n"
        out += "wrapper: " + (["oh-body"] + ReaderDocument.wrapperClasses(s.treatment, appearance: appearance)
            + (s.bodyClass.isEmpty ? [] : [s.bodyClass])).joined(separator: " ") + s.bodyAttributes + "\n"
        if !s.bodyAttributeCSS.isEmpty { out += "body-attributes: \(s.bodyAttributeCSS)\n" }
        for css in s.headCSS { out += "css: \(css)\n" }
        out += "body:\n\(s.bodyHTML)\n"
        if appearance == .light {
            out += "counts: remote \(s.remoteReferences), blocked \(s.blockedRemote), trackers \(s.trackers) "
            out += "\(s.trackerDomains), inline \(s.inlineContentIDs), quoted \(s.hasQuotedText)\n"
            for link in s.suspiciousLinks {
                out += "link: \(link.reasons.map(\.rawValue)) shows \(link.displayedDestination ?? "-") goes \(link.actualDestination)\n"
            }
        }
    }
    return out
}
