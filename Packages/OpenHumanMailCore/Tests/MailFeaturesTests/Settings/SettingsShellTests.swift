import Foundation
import MailActions
import MailModel
import Testing
@testable import MailFeatures

@MainActor
struct SettingsShellTests {
    @Test func theShellListsThePagesInOrderWithImportanceAfterNotificationsAndAdvancedLast() {
        let f = SettingsFixture()
        let model = SettingsShellModel(environment: f.env)
        let ids = model.pages.map(\.id)
        #expect(ids == ["general", "accounts", "notifications", "importance", "splitInbox", "sidebar", "snippets", "search", "shortcuts",
                        "ai", "calendar", "appearance", "privacy", "blocked", "platform", "advanced"])
        #expect(model.selected == "general")
        let off = SettingsShellModel(environment: SettingsFixture(flags: FeatureFlags().with(.notifications, false)).env)
        #expect(Array(off.pages.map(\.id).prefix(3)) == ["general", "accounts", "importance"])
        #expect(Array(off.pages.map(\.id).suffix(2)) == ["platform", "advanced"])
    }

    @Test func aModuleThatIsOffRemovesItsPage() {
        let on = SettingsShellModel(environment: SettingsFixture().env)
        let off = SettingsShellModel(environment: SettingsFixture(flags: FeatureFlags().with(.notifications, false)).env)
        #expect(on.pages.contains { $0.id == "notifications" })
        #expect(!off.pages.contains { $0.id == "notifications" })
        #expect(!off.pages.isEmpty, "the app and its settings still work with a module off")
    }

    @Test func pagesTheModulesRegisterAppearAndGeneralRowsDoNot() {
        let f = SettingsFixture()
        #expect(f.env.modules.settingsPages.contains { $0.id == "importance" })
        let model = SettingsShellModel(environment: f.env)
        #expect(model.pages.contains { $0.id == "importance" && $0.builtIn == nil })
        #expect(!model.pages.contains { $0.id.hasPrefix("general.") }, "Open at login and Dock badge are General rows")
        let titles = model.pages.map(\.id)
        #expect(Set(titles).count == titles.count, "no duplicate page")
    }

    @Test func theLastPageIsRememberedWhenDefaultsAreGivenAndIgnoredForFakeData() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let registry = SettingsFixture().env.modules
        let availability = SettingsAvailability(hasCommands: true, hasSettings: true, hasAccounts: true)
        let first = SettingsShellModel(registry: registry, availability: availability, defaults: defaults)
        first.selected = "privacy"
        let second = SettingsShellModel(registry: registry, availability: availability, defaults: defaults)
        #expect(second.selected == "privacy")
        defaults.set("nonsense", forKey: SettingsShellModel.lastPageKey)
        #expect(SettingsShellModel(registry: registry, availability: availability, defaults: defaults).selected == "general")
        let fake = SettingsShellModel(environment: SettingsFixture().env, defaults: defaults)
        fake.selected = "advanced"
        #expect(defaults.string(forKey: SettingsShellModel.lastPageKey) == "nonsense")
    }

    @Test func storedItemsAreEditableExactlyWhenThereIsAWritePort() {
        let normal = SettingsFixture().availability
        #expect(normal.hasCommands && normal.canEditSettings && normal.storedItemsNote == nil)
        let noWrite = SettingsAvailability(hasCommands: false, hasSettings: true, hasAccounts: false)
        #expect(!noWrite.hasCommands && noWrite.canEditSettings)
        #expect(noWrite.storedItemsNote == "Editing isn't available here.")
    }
}

@MainActor
struct FeaturesAndPlatformTests {
    @Test func everyCompiledInModuleHasASwitchAndTheStoredFlagDecidesTheNextLaunch() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let f = SettingsFixture()
        let model = FeaturesSettingsModel(modules: ModuleList.all, registered: f.env.modules.modules, defaults: defaults)
        #expect(model.rows.count == ModuleList.all.count)
        #expect(model.rows.allSatisfy { !$0.title.isEmpty })
        #expect(!model.needsRestart)
        model.set(.snooze, enabled: false)
        #expect(defaults.object(forKey: FeatureFlags.key(.snooze)) as? Bool == false)
        #expect(model.needsRestart)
        #expect(model.rows.first { $0.id == .snooze }?.needsRestart == true)
        let flags = FeatureFlags.load(from: defaults, modules: ModuleList.all.map { type(of: $0).id })
        let next = SettingsFixture(flags: flags)
        #expect(!next.env.modules.modules.contains(.snooze))
        #expect(FeaturesSettingsModel(modules: ModuleList.all, registered: next.env.modules.modules, defaults: defaults).needsRestart == false)
    }

    @Test func fakeDataNeverWritesTheRealFlags() {
        let f = SettingsFixture()
        let before = UserDefaults.standard.object(forKey: FeatureFlags.key(.snooze))
        let model = FeaturesSettingsModel(environment: f.env)
        model.set(.snooze, enabled: !(model.rows.first { $0.id == .snooze }?.isOn ?? true))
        #expect(UserDefaults.standard.object(forKey: FeatureFlags.key(.snooze)) as? Bool == before as? Bool)
    }

    @Test func thePlatformPageNamesEveryNotarizationGatedFeatureAndOffersNoSwitch() {
        let model = PlatformFeaturesModel()
        let ids = Set(model.rows.map(\.id))
        #expect(ids == ["services", "menuBarExtra", "globalHotkey", "appIntents", "spotlight", "focusFilters", "writingTools"])
        #expect(model.rows.allSatisfy { !$0.isAvailable && $0.status.contains("Not in this build yet") })
        let later = PlatformFeaturesModel(availability: PlatformFeatureAvailability(available: ["spotlight"]))
        #expect(later.rows.first { $0.id == "spotlight" }?.isAvailable == true)
        #expect(later.rows.filter(\.isAvailable).count == 1)
    }
}
