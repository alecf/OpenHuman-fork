import AppKit
import MailTheme
import MailUI

@MainActor
public final class SystemAppearanceMonitor {
    private var appearanceObservation: NSKeyValueObservation?
    private var contrastObserver: (any NSObjectProtocol)?

    public init(store: ThemeStore, application: NSApplication = .shared, workspace: NSWorkspace = .shared) {
        store.systemAppearance = Self.appearance(of: application.effectiveAppearance)
        store.increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        store.reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        appearanceObservation = application.observe(\.effectiveAppearance, options: [.new]) { [weak store] _, _ in
            MainActor.assumeIsolated { store?.systemAppearance = Self.appearance(of: NSApplication.shared.effectiveAppearance) }
        }
        contrastObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak store] _ in
            MainActor.assumeIsolated {
                store?.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                store?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    isolated deinit {
        appearanceObservation?.invalidate()
        if let contrastObserver { NSWorkspace.shared.notificationCenter.removeObserver(contrastObserver) }
    }

    public nonisolated static func appearance(of appearance: NSAppearance) -> ThemeAppearance {
        appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua ? .dark : .light } ?? .light
    }
}

extension NSWindow {
    public func applyThemeAppearance(_ theme: ResolvedTheme) {
        let name: NSAppearance.Name = theme.appearance == .dark ? .darkAqua : .aqua
        if appearance?.name != name { appearance = NSAppearance(named: name) }
    }
}

@MainActor
public enum MacFontCatalog {
    private static var cache: Set<String>?

    public static var families: [String] { NSFontManager.shared.availableFontFamilies }

    public static func isInstalled(_ family: String) -> Bool {
        if cache == nil { cache = Set(families) }
        return cache?.contains(family) ?? false
    }

    public static func invalidate() { cache = nil }
}
