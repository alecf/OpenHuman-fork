import Foundation

struct PlatformServices: Sendable {
    var isAppActive: @MainActor @Sendable () -> Bool
    var activateApp: @MainActor @Sendable () -> Void

    init(isAppActive: @escaping @MainActor @Sendable () -> Bool, activateApp: @escaping @MainActor @Sendable () -> Void) {
        self.isAppActive = isAppActive
        self.activateApp = activateApp
    }

    // Why: the app installs its platform when it composes itself; until then the app counts as inactive
    @MainActor static var current = PlatformServices(isAppActive: { false }, activateApp: {})
}
