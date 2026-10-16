import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
final class SettingsWindowRecorder {
    var opens = 0

    func install(on navigator: SettingsNavigator) {
        navigator.openWindow = { self.opens += 1 }
    }
}

@MainActor
@Suite struct SettingsPaletteTests {
    @Test func everySettingsPageTheWindowListsHasAPaletteEntryWithItsTitle() {
        let f = SettingsFixture()
        let pages = SettingsShellModel.pages(for: f.env.modules)
        #expect(Set(ActionCatalog.settingsPages.map(\.id)) == Set(pages.map { ActionID.settingsPage($0.id) }),
                "the catalog's list and the window's pages agree")
        for page in pages {
            #expect(ActionCatalog.descriptor(.settingsPage(page.id))?.title == "Settings: \(page.title)", "\(page.id)")
        }
    }

    @Test func aSettingsEntryOpensTheWindowAtItsPage() async {
        let f = ActionFixture()
        await f.loaded()
        let navigator = f.env.settingsNavigator
        let recorder = SettingsWindowRecorder()
        recorder.install(on: navigator)
        #expect(await f.run(.settingsPage("notifications"), source: .palette))
        #expect(recorder.opens == 1 && navigator.requestedPage == "notifications")
        let shell = SettingsShellModel(environment: f.env)
        #expect(shell.takeRequest(from: navigator))
        #expect(shell.selected == "notifications" && navigator.requestedPage == nil, "taken once")
        #expect(!shell.takeRequest(from: navigator))
        navigator.open("nonsense")
        #expect(!shell.takeRequest(from: navigator) && shell.selected == "notifications" && navigator.requestedPage == nil)
    }

    @Test func theEntriesAreHiddenWithoutAWindowToOpenOrAPageToShow() async {
        let f = ActionFixture(flags: FeatureFlags().with(.notifications, false))
        await f.loaded()
        #expect(f.registry.availability(.settingsPage("general"), host: f.router) == .hidden, "nothing can open Settings yet")
        #expect(f.registry.availability(.addAccount, host: f.router) == .hidden)
        SettingsWindowRecorder().install(on: f.env.settingsNavigator)
        #expect(f.registry.availability(.settingsPage("general"), host: f.router) == .enabled)
        #expect(f.registry.availability(.settingsPage("importance"), host: f.router) == .enabled, "a module's page")
        #expect(f.registry.availability(.settingsPage("notifications"), host: f.router) == .hidden, "its module is off")
    }

    @Test func addAccountOpensAccountsAndTheAccountsPageStartsTheSignInOnce() async throws {
        let f = SettingsFixture()
        let navigator = f.env.settingsNavigator
        let recorder = SettingsWindowRecorder()
        recorder.install(on: navigator)
        #expect(await f.env.actions.run(.addAccount, source: .palette, host: nil))
        #expect(recorder.opens == 1 && navigator.requestedPage == "accounts" && navigator.addAccountRequested)
        let model = AccountsSettingsModel(environment: f.env)
        f.store.enqueueSignIn(.succeed(email: "new.person@example.org", displayName: "New Person"))
        let signIn = try #require(model.addAccountIfRequested(by: navigator))
        await signIn.value
        #expect(try await f.accounts().contains { $0.email == "new.person@example.org" })
        #expect(model.errorMessage == nil && !navigator.addAccountRequested)
        #expect(model.addAccountIfRequested(by: navigator) == nil, "one sign-in per request")
    }

    @Test func thePaletteNamesTheAccountsItSwitchesTo() async throws {
        let f = ActionFixture(corpus: .rich(threadCount: 20, now: fixedNow), location: nil)
        await eventually { f.router.accounts.count == 2 }
        let names = f.router.accounts.map { $0.account.alias ?? $0.account.displayName ?? $0.account.email }
        #expect(f.router.actionContext().accountTitles == names)
        let palette = f.registry.palette
        palette.open(host: f.router)
        palette.query = "switch"
        let second = try #require(palette.rows.first { $0.action == .switchToAccount(2) })
        #expect(second.title == "Switch to \(names[1])")
        #expect(second.keycaps == ["⌃2"])
    }
}

@MainActor
@Suite struct RefreshActionTests {
    @Test func refreshAsksTheEngineToSyncTheWayTheCLIDoes() async throws {
        let f = ActionFixture()
        await f.loaded()
        #expect(try await f.store.get(AppSettings.syncRequestAt) == nil)
        #expect(AppSettings.syncRequestAt.name == "sync.request_at", "the key the engine watches")
        #expect(await f.run(.refresh, source: .palette))
        let first = try #require(try await f.store.get(AppSettings.syncRequestAt))
        #expect(first > 1_700_000_000_000, "epoch milliseconds")
        #expect(await f.run(.refresh, source: .menu))
        #expect(try #require(try await f.store.get(AppSettings.syncRequestAt)) >= first)
        #expect(f.toastMessages.isEmpty, "the status area shows the sync; no toast")
    }

    @Test func refreshIsHiddenWithoutASettingsPort() async throws {
        let bare = AppEnvironment(data: FakeMailStore(corpus: .make(threadCount: 3, now: fixedNow), options: .init()),
                                  isFake: true, featureFlags: FeatureFlags())
        #expect(bare.actions.availability(.refresh, host: nil) == .hidden, "no settings port, no engine to ask")
    }
}

@MainActor
@Suite struct SendLaterNoteTests {
    @Test func theNoteSaysTheFirstRunningMacSendsIt() {
        let note = GeneralSettingsModel.sendLaterNote
        #expect(note.contains("first Mac running Mail"))
        #expect(note.contains("when you next open Mail") && note.contains("asks first"))
        #expect(!note.contains("Mac is off") && !note.contains("held by Gmail"))
    }
}

@MainActor
@Suite(.serialized)
struct NewMailModeTests {
    @Test func theModePersistsAndAnAccountSwitchedOffBeforeReadsAsOff() throws {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: SystemPreferences.newMailKey(AccountID(5)))
        let a = SystemPreferences(defaults: defaults)
        #expect(a.newMailMode(AccountID(5)) == .off && a.newMailMode(AccountID(6)) == .important, "Important only by default")
        a.setNewMailMode(.allInbox, for: AccountID(6))
        a.setNewMailMode(.important, for: AccountID(5))
        let b = SystemPreferences(defaults: defaults)
        #expect(b.newMailMode(AccountID(6)) == .allInbox && b.newMailMode(AccountID(5)) == .important)
        #expect(defaults.object(forKey: SystemPreferences.newMailKey(AccountID(5))) == nil, "the mode is the one place")
        b.setNewMailEnabled(true, for: AccountID(6))
        #expect(b.newMailMode(AccountID(6)) == .allInbox && b.newMailEnabled(AccountID(6)))
        b.setNewMailEnabled(false, for: AccountID(6))
        #expect(b.newMailMode(AccountID(6)) == .off && !b.newMailEnabled(AccountID(6)))
        b.setNewMailEnabled(true, for: AccountID(6))
        #expect(b.newMailMode(AccountID(6)) == .important)
        b.setNewMailMode(.allInbox, for: AccountID(6))
        b.removeAccount(AccountID(6))
        #expect(defaults.object(forKey: SystemPreferences.newMailModeKey(AccountID(6))) == nil)
        #expect(SystemPreferences(defaults: defaults).newMailMode(AccountID(6)) == .important)
        #expect(NewMailNotifications.allCases.map(\.title) == ["Important only", "All inbox mail", "Off"])
    }

    @Test func theSettingsMenuStoresTheModeAndOnlyAModeThatNotifiesAsksPermission() async throws {
        let f = SystemFixture(authorization: .notDetermined)
        f.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { f.env.system.notifications != nil }
        let model = NotificationsSettingsModel(environment: f.env)
        model.start()
        await eventually(timeout: .seconds(15)) { !model.accounts.isEmpty }
        #expect(model.accounts.allSatisfy { $0.mode == .important && $0.isOn }, "Important only by default")
        await model.setNewMailMode(.off, for: f.account)
        #expect(f.env.system.preferences.newMailMode(f.account) == .off)
        #expect(model.accounts.first { $0.id == f.account }?.isOn == false)
        #expect(f.notifier.authorizationRequests == 0, "turning it off asks nothing")
        await model.setNewMailMode(.allInbox, for: f.account)
        #expect(f.env.system.preferences.newMailMode(f.account) == .allInbox)
        #expect(model.accounts.first { $0.id == f.account }?.mode == .allInbox)
        #expect(f.notifier.authorizationRequests == 1)
        #expect(NotificationsSettingsModel.newMailNote.contains("importance rules"))
    }
}
