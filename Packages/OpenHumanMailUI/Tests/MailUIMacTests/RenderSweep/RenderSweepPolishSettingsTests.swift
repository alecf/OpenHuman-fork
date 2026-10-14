import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.builtIns)
    func autoLabelsAndPersonalization(_ theme: SweepTheme) async throws {
        let center = SweepOverlayFixture.aiCenter()
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 200, now: SweepClock.now),
                                              options: .init(remoteAck: .immediate, now: { SweepClock.now }),
                                              featureFlags: FeatureFlags(), ai: center)
        let store = theme.makeStore()

        let labels = sweepStandaloneWindow(SettingsPageScaffold(title: "Auto labels") {
            AutoLabelsSection(environment: environment)
        }, store: store, size: NSSize(width: 760, height: 1400))
        defer { labels.orderOut(nil) }
        try await sweepShoot(labels, screen: "settings-auto-labels", theme: theme, settle: .milliseconds(700))

        let ai = sweepStandaloneWindow(SettingsPageScaffold(title: "AI") {
            AISettingsSection(center: center, environment: environment, listsUnavailableModels: false)
        }, store: store, size: NSSize(width: 760, height: 2000))
        defer { ai.orderOut(nil) }
        try await sweepShoot(ai, screen: "settings-personalization", theme: theme, settle: .milliseconds(700))
    }
}
