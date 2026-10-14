import AppKit
import MailFeatures
import Testing
@testable import MailUIMac

@MainActor
struct AboutPanelTests {
    @Test func anEarlyDevelopmentBuildShowsTheNoticeUnderTheVersion() throws {
        let label = BuildLabel(version: "0.1.0", build: "1001", channel: "early-development")
        let options = AboutPanel.options(for: label)
        #expect(options.count == 1, "the version, name and icon stay the standard ones")
        let credits = try #require(options[.credits] as? NSAttributedString)
        #expect(credits.string == "Early development build — expect rough edges. Please send feedback.")
        #expect(credits.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
    }

    @Test func otherChannelsKeepTheStandardPanel() {
        #expect(AboutPanel.options(for: BuildLabel(version: "1.0.0", build: "7", channel: "")).isEmpty)
    }
}
