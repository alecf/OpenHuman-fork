import Foundation
import MailModel
import OpenHumanAI
import OpenHumanCore
import Testing
@testable import OpenHumanMailLive

@Suite struct AISettingsOnboardingTests {
    @Test func belowMacOS27TheWelcomeGuideSaysApplesModelNeedsANewerSystem() async {
        let suite = ScopedDefaults("openhuman.test.ai-onboarding")
        defer { suite.cleanup() }
        let onboarding = AISettingsOnboarding(store: AISettingsStore(suiteName: suite.name),
                                              availability: { .unavailable(reason: .requiresNewerOS) })
        let status = await onboarding.onDeviceStatus()
        #expect(status == .unavailable(hint: "Apple's on-device model in Mail needs macOS 27"))
    }
}
