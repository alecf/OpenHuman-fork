import Foundation
import MailActions
import MailFeatures
import MailModel
import MailTheme
import Testing
@testable import MailUI

@MainActor
struct ThemeActionsTests {
    private func rig() -> (registry: ActionRegistry, store: ThemeStore, persisted: MemoryThemePreferencesStore) {
        let persisted = MemoryThemePreferencesStore()
        let store = ThemeStore(preferencesStore: persisted)
        let registry = ActionRegistry()
        ThemeActionHandler.install(in: registry, store: store)
        return (registry, store, persisted)
    }

    @Test func theCatalogHasTheThemeActionsAsViewEffects() {
        let ids = ["theme.light", "theme.dark", "theme.system"] + ActionCatalog.builtInAccents.map { "theme.accent.\($0)" }
        for id in ids {
            let descriptor = ActionCatalog.descriptor(ActionID(id))
            #expect(descriptor != nil, "\(id)")
            #expect(descriptor?.effect == .view && descriptor?.changesMail == false, "\(id)")
            #expect(descriptor?.appearsInPalette == true, "\(id)")
        }
        #expect(Set(ActionCatalog.builtInAccents) == Set(ThemeLibrary.builtIn.accentIDs))
    }

    @Test func modeAndAccentActionsWriteTheSharedPreferences() {
        let (registry, store, persisted) = rig()
        #expect(registry.perform(.themeDark, source: .palette, host: nil))
        #expect(store.preferences.mode == .dark && store.resolved.appearance == .dark)
        #expect(persisted.load()?.mode == .dark)
        #expect(registry.perform(.themeLight, source: .menu, host: nil))
        #expect(store.preferences.mode == .light)
        #expect(registry.perform(.themeSystem, source: .menu, host: nil))
        #expect(store.preferences.mode == .system)
        #expect(registry.perform(.themeAccent("iris"), source: .palette, host: nil))
        #expect(store.preferences.accentID == "iris" && store.resolved.accentID == "iris")
        #expect(persisted.load()?.accentID == "iris")
    }

    @Test func aChangeMadeElsewhereIsWhatTheMenuReads() {
        let (_, store, _) = rig()
        store.preferences.mode = .dark
        store.preferences.accentID = "pine"
        #expect(store.preferences.mode == .dark && store.resolved.accentID == "pine")
        #expect(ThemeActionHandler.action(for: store.preferences.mode) == .themeDark)
    }

    @Test(arguments: [SafeModeInfo.readOnly, SafeModeInfo.normal])
    func theyWorkInReadOnlySafeMode(safeMode: SafeModeInfo) {
        let (registry, store, _) = rig()
        var context = ActionContext()
        context.safeMode = safeMode
        context.canWrite = false
        for id in [ActionID.themeLight, .themeDark, .themeSystem, .themeAccent("blue")] {
            #expect(registry.availability(id, host: nil, context: context) == .enabled, "\(id.rawValue)")
        }
        #expect(registry.perform(.themeDark, source: .palette, host: nil, context: context))
        #expect(store.preferences.mode == .dark)
    }

    @Test func anUnknownAccentIsRefused() {
        let (registry, store, _) = rig()
        #expect(!registry.perform(ActionID.themeAccent("chartreuse"), source: .palette, host: nil))
        #expect(store.preferences.accentID == nil)
        #expect(ActionID("theme.accent.").themeAccentName == nil)
        #expect(ActionID.themeAccent("iris").themeAccentName == "iris")
    }

    @Test func thePaletteListsThem() {
        let (registry, _, _) = rig()
        let titles = registry.descriptors.filter(\.appearsInPalette).map(\.title)
        #expect(titles.contains("Appearance: Dark") && titles.contains("Accent: Iris"))
    }
}
