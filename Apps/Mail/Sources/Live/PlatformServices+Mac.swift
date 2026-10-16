import AppKit

extension PlatformServices {
    static let mac = PlatformServices(isAppActive: { NSApplication.shared.isActive }, activateApp: { NSApp.activate() })
}
