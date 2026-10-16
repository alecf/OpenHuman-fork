import Foundation
import MailActions
import MailFakes
import MailModel
import Testing
@testable import MailFeatures

@MainActor
@Suite struct SendToDeviceOptionTests {
    private func scratch() throws -> (UserDefaults, String) {
        let name = "send-to-device-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private func installedCenter() -> (SendFeedbackCenter, () -> Int) {
        let center = SendFeedbackCenter()
        var made = 0
        center.makeModel = {
            made += 1
            return SendFeedbackModel(SendFeedbackDependencies(runner: nil, appInfo: { FeedbackBundlerTests.app }))
        }
        return (center, { made })
    }

    @Test func theOptionIsOffByDefaultInEveryBuild() throws {
        let (defaults, name) = try scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        for availability in [DevFeedbackAvailability.off, .devTools] {
            let options = DeveloperOptions(devFeedback: availability, defaults: defaults)
            #expect(!options.sendToDevice && !options.offersSendToDevice, "\(availability)")
        }
        let developer = DeveloperOptions(devFeedback: .devTools, defaults: defaults)
        developer.isOn = true
        #expect(developer.showsDeveloperItems && !developer.offersSendToDevice)
    }

    @Test func theOptionIsRememberedWhereOfferedAndIgnoredInAPublicBuild() throws {
        let (defaults, name) = try scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let devTools = DeveloperOptions(devFeedback: .devTools, defaults: defaults)
        devTools.sendToDevice = true
        #expect(devTools.offersSendToDevice)
        #expect(DeveloperOptions(devFeedback: .devTools, defaults: defaults).offersSendToDevice)

        let release = DeveloperOptions(devFeedback: .off, defaults: defaults)
        #expect(!release.isAvailable && !release.offersSendToDevice)
        release.sendToDevice = false
        #expect(DeveloperOptions(devFeedback: .devTools, defaults: defaults).offersSendToDevice,
                "a run that does not offer the option leaves the stored choice alone")
    }

    @Test func theSheetOpensOnlyWhileTheOptionIsOn() {
        let (center, made) = installedCenter()
        #expect(!center.canBegin, "installed by the app, but the option is off")
        center.begin()
        #expect(made() == 0 && !center.isPresented)

        var offered = true
        center.isOffered = { offered }
        #expect(center.canBegin)
        center.begin()
        #expect(made() == 1 && center.isPresented)

        center.isPresented = false
        offered = false
        #expect(!center.canBegin)
        center.begin()
        #expect(made() == 1 && !center.isPresented)
    }

    @Test func thePaletteEntryIsHiddenWhileTheOptionIsOff() {
        let f = ActionFixture()
        let center = f.env.system.sendFeedback
        center.makeModel = { SendFeedbackModel(SendFeedbackDependencies(runner: nil, appInfo: { FeedbackBundlerTests.app })) }
        #expect(f.registry.availability(.sendFeedback, host: f.router) == .hidden)
        center.isOffered = { true }
        #expect(f.registry.availability(.sendFeedback, host: f.router) == .enabled)
    }

    @Test func theWordingNamesNoPersonalDevice() throws {
        let descriptor = try #require(ActionCatalog.descriptor(.sendFeedback))
        let texts = [descriptor.title, SendFeedbackCenter.menuTitle, SendFeedbackCenter.sheetTitle,
                     SendFeedbackCenter.settingsTitle, SendFeedbackCenter.settingsDetail] + descriptor.paletteKeywords
        for text in texts {
            #expect(!text.lowercased().contains("mac mini"), "\(text)")
            #expect(!text.lowercased().contains("my mac"), "\(text)")
        }
        #expect(descriptor.title.localizedCaseInsensitiveContains("another device"))
        #expect(SendFeedbackCenter.menuTitle.hasSuffix("…") && SendFeedbackCenter.settingsDetail.contains("Tailscale"))
    }
}
