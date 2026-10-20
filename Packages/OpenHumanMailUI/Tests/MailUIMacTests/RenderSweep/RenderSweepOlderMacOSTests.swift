import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanAI
import OpenHumanAITesting
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func aiSettingsBelowMacOS27(_ theme: SweepTheme) async throws {
        let claude = ScriptedProvider(id: .agentClaude, displayName: "Claude Code",
                                      capabilities: .fake(dataLocation: .thirdParty(vendor: "Anthropic")))
        let center = AICenter.make(registry: ProviderRegistry(providers: [claude]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore()), appleModel: .unsupported)
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 200, now: SweepClock.now),
                                              options: .init(remoteAck: .immediate, now: { SweepClock.now }),
                                              featureFlags: FeatureFlags(), ai: center)
        let ai = sweepStandaloneWindow(SettingsPageScaffold(title: "AI") {
            AISettingsSection(center: center, environment: environment, listsUnavailableModels: false)
        }, store: theme.makeStore(), size: NSSize(width: Self.settingsPageWidth, height: 900))
        defer { ai.orderOut(nil) }
        try await sweepShoot(ai, screen: "settings-ai-older-macos", theme: theme, settle: .milliseconds(700))
    }
}
