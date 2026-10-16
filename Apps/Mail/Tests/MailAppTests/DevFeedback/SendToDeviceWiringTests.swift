import Foundation
import MailFakes
import MailFeatures
import OpenHumanCore
import Testing
@testable import OpenHumanMail

@MainActor
struct SendToDeviceWiringTests {
    @Test func theSheetsEntryPointsFollowTheDeveloperOption() throws {
        let defaults = ScopedDefaults("openhuman.test.send-to-device-wiring")
        defer { defaults.cleanup() }
        let environment = AppEnvironment.fake(corpus: .make(threadCount: 1, now: Date(timeIntervalSince1970: 1_791_000_000)))
        let center = environment.system.sendFeedback

        let devTools = DeveloperOptions(devFeedback: .devTools, defaults: defaults)
        SendFeedbackSupport.install(in: environment, window: nil, options: devTools)
        #expect(!center.canBegin, "off by default")
        devTools.sendToDevice = true
        #expect(center.canBegin)

        let release = DeveloperOptions(devFeedback: .off, defaults: defaults)
        SendFeedbackSupport.install(in: environment, window: nil, options: release)
        #expect(!center.canBegin, "a public build never shows it, whatever an earlier run stored")
    }

    @Test func theDeveloperOptionNamesNoParticularDevice() {
        #expect(DeveloperOptionsSection.sendToDeviceTitle == "Send to another device via Tailscale")
        #expect(DeveloperOptionsSection.sendToDeviceDetail.contains(SendFeedbackCenter.menuTitle))
        #expect(!DeveloperOptionsSection.sendToDeviceDetail.lowercased().contains("mac mini"))
    }
}
