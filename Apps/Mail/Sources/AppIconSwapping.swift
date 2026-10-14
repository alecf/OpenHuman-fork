import AppKit

@MainActor
protocol AppIconSwapping {
    func showOpenIcon()
    func restoreBundleIcon()
}

@MainActor
struct NSAppIconSwapper: AppIconSwapping {
    func showOpenIcon() {
        guard let image = NSImage(named: AppIconController.openImageName) else { return }
        NSApp.applicationIconImage = image
    }

    func restoreBundleIcon() { NSApp.applicationIconImage = nil }
}

@MainActor
final class AppIconController {
    static let openImageName = "AppIconOpen"
    static let settingKey = "appearance.open_icon_while_running"
    static let shared = AppIconController(swapper: NSAppIconSwapper())

    private let swapper: any AppIconSwapping
    private let defaults: UserDefaults
    private let underTest: Bool

    init(swapper: any AppIconSwapping, defaults: UserDefaults = .standard,
         underTest: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil) {
        self.swapper = swapper
        self.defaults = defaults
        self.underTest = underTest
    }

    var isEnabled: Bool { defaults.object(forKey: Self.settingKey) as? Bool ?? true }

    func applyAtLaunch() {
        guard !underTest, isEnabled else { return }
        swapper.showOpenIcon()
    }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.settingKey)
        guard !underTest else { return }
        if on { swapper.showOpenIcon() } else { swapper.restoreBundleIcon() }
    }
}
