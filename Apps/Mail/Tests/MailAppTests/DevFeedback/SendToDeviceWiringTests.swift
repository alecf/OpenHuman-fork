import Foundation
import MailFakes
import MailFeatures
import Testing
@testable import OpenHumanMail

@MainActor
struct SendToDeviceWiringTests {
    @Test func theSheetsEntryPointsFollowTheDeveloperOption() throws {
        let suite = "send-to-device-wiring-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let environment = AppEnvironment.fake(corpus: .make(threadCount: 1, now: Date(timeIntervalSince1970: 1_791_000_000)))
        let center = environment.system.sendFeedback

        let debug = DeveloperOptions(environment: [:], devFeedback: .debugBuild, defaults: defaults)
        SendFeedbackSupport.install(in: environment, window: nil, options: debug)
        #expect(!center.canBegin, "off by default")
        debug.sendToDevice = true
        #expect(center.canBegin)

        let release = DeveloperOptions(environment: [:], devFeedback: .off, defaults: defaults)
        SendFeedbackSupport.install(in: environment, window: nil, options: release)
        #expect(!center.canBegin, "a public build never shows it, whatever an earlier run stored")
    }

    @Test func theDeveloperOptionNamesNoParticularDevice() {
        #expect(DeveloperOptionsSection.sendToDeviceTitle == "Send to another device via Tailscale")
        #expect(DeveloperOptionsSection.sendToDeviceDetail.contains(SendFeedbackCenter.menuTitle))
        #expect(!DeveloperOptionsSection.sendToDeviceDetail.lowercased().contains("mac mini"))
    }
}
