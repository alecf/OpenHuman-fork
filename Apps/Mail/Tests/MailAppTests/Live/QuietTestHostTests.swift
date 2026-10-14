import AppKit
import Testing
@testable import OpenHumanMail

@MainActor
@Suite struct QuietTestHostTests {
    @Test func theTestHostCannotTakeFocus() {
        #expect(QuietTestHost.isActive)
        #expect(NSApp.activationPolicy() == .prohibited)
        #expect(!NSApp.isActive)
    }

    @Test func theSceneWindowIsInvisibleButStillThere() async {
        func sceneWindow() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(DevFeedbackRuntime.mainWindowID) == true && $0.isVisible }
        }
        await eventually("scene window") { sceneWindow() != nil }
        guard let window = sceneWindow() else { return }
        #expect(window.alphaValue == 0)
        #expect(window.ignoresMouseEvents)
        #expect(window.isVisible, "tests that need the real window can still use it")
        #expect(!NSApp.isActive)
    }

    @Test func outsideTheTestHostNothingChanges() {
        #expect(QuietTestHost.isActive == (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil))
    }
}
