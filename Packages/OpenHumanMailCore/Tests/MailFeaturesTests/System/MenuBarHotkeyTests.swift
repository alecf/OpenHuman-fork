import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized)
struct MenuBarItemTests {
    private func ready(_ f: SystemFixture) async {
        f.env.router.start()
        f.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { f.env.router.active?.list?.state == .loaded }
    }

    private func importantUnread(_ f: SystemFixture, accounts: [AccountID]) async throws -> Int {
        var total = 0
        for account in accounts { total += try await first(f.store.counts(account))?.importantUnread ?? 0 }
        return total
    }

    @Test func offByDefaultSoNothingIsInTheMenuBar() async throws {
        let f = SystemFixture()
        f.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { f.env.system.notifications != nil }
        #expect(f.env.system.menuBar == nil)
        #expect(!f.menuBar.isShown && f.menuBar.showCalls == 0 && f.menuBar.countHistory.isEmpty)
        #expect(!f.env.modules.modules.contains(.menuBarExtra))
        #expect(!f.env.system.preferences.menuBarEnabled)
    }

    @Test func flagOnAtLaunchShowsTheItemWithTheImportantUnreadCount() async throws {
        let f = SystemFixture(corpus: .small, flags: FeatureFlags().with(.menuBarExtra, true))
        f.env.runLaunchTasks()
        f.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { f.env.system.menuBar != nil }
        let model = try #require(f.env.system.menuBar)
        #expect(f.menuBar.isShown && f.menuBar.showCalls == 1)
        await eventually(timeout: .seconds(15)) { model.total > 0 }
        let expected = try await importantUnread(f, accounts: FakeCorpus.small.accounts.map(\.id))
        #expect(model.total == expected, "summed over accounts, important only")
        await eventually(timeout: .seconds(15)) { f.menuBar.count == DockBadgeModel.text(for: expected) }
        let before = f.menuBar.count
        f.store.deliverMessage(account: f.account, from: EmailAddress(name: "A", email: "a@x.example"), subject: "Important", important: true)
        f.store.deliverMessage(account: f.account, from: EmailAddress(name: "B", email: "b@x.example"), subject: "Promo")
        await eventually(timeout: .seconds(15)) { f.menuBar.count != before }
        #expect(f.menuBar.count == DockBadgeModel.text(for: expected + 1))
    }

    @Test func theCountSettingPicksImportantInboxOrNoNumberAndLeavesTheDockAlone() async throws {
        let f = SystemFixture(corpus: .make(threadCount: 30, now: fixedNow))
        f.env.system.setMenuBar(enabled: true)
        let model = try #require(f.env.system.menuBar)
        await eventually(timeout: .seconds(15)) { model.total > 0 }
        let counts = try #require(await first(f.store.counts(f.account)))
        f.env.system.preferences.menuBarCount = .inbox
        await eventually(timeout: .seconds(15)) { model.total == counts.inboxUnread }
        await eventually(timeout: .seconds(15)) { f.menuBar.count == DockBadgeModel.text(for: counts.inboxUnread) }
        f.env.system.preferences.menuBarCount = .off
        await eventually(timeout: .seconds(15)) { f.menuBar.count == "" }
        #expect(f.menuBar.isShown, "no number still shows the icon")
        f.env.system.preferences.menuBarCount = .important
        await eventually(timeout: .seconds(15)) { model.total == counts.importantUnread ?? 0 }
        #expect(f.dock.history.isEmpty, "the menu bar's counter never writes the Dock tile")
        #expect(f.env.system.preferences.dockBadge == .important, "the Dock badge keeps its own setting")
    }

    @Test func theSwitchShowsAndRemovesTheItemAtOnceAndTheNextLaunchFollowsIt() async throws {
        let f = SystemFixture()
        let settings = MenuBarSettingsModel(system: f.env.system)
        #expect(!settings.isOn && settings.status == "Off.")
        settings.setOn(true)
        #expect(settings.isOn && f.menuBar.isShown)
        let defaults = f.env.system.preferences.defaults
        #expect(FeatureFlags.load(from: defaults).isEnabled(.menuBarExtra, default: false))
        settings.setOn(false)
        #expect(!settings.isOn && !f.menuBar.isShown && f.env.system.menuBar == nil)
        #expect(f.menuBar.count == "", "the number is cleared before the item goes")
        #expect(!FeatureFlags.load(from: defaults).isEnabled(.menuBarExtra, default: false))
        settings.setOn(true)
        #expect(f.menuBar.isShown && f.menuBar.showCalls == 2)
    }

    @Test func theMenuListsTheNewestUnreadImportantConversationsAndAClickOpensOne() async throws {
        let f = SystemFixture(corpus: .make(threadCount: 3, now: fixedNow), flags: FeatureFlags().with(.menuBarExtra, true))
        await ready(f)
        await eventually(timeout: .seconds(15)) { f.menuBar.isShown }
        let sender = EmailAddress(name: "Sam Sample", email: "sam@x.example")
        _ = f.store.deliverMessage(account: f.account, from: sender, subject: "Invoice question", important: true)
        _ = f.store.deliverMessage(account: f.account, from: EmailAddress(name: "Shop", email: "shop@x.example"), subject: "Sale")
        await eventually(timeout: .seconds(15)) { f.menuBar.threads.contains { $0.detail == "Invoice question" } }
        let items = f.menuBar.threads
        #expect(items.count <= MenuBarModel.defaultThreadLimit && items.allSatisfy(\.isImportant), "important only, capped")
        #expect(!items.contains { $0.detail == "Sale" }, "a promotion does not make the list")
        let mine = try #require(items.first { $0.detail == "Invoice question" })
        #expect(mine.title == "Sam Sample")
        f.menuBar.chooseThread(mine.key)
        #expect(f.active.windowShows == 1)
        await eventually(timeout: .seconds(15)) { f.env.router.account?.id == mine.key.account }
        #expect(f.env.undo?.nextUndo == nil, "opening changes nothing")
    }

    @Test func withPreviewsOffTheListCarriesNeitherSenderNorSubject() async throws {
        let f = SystemFixture(corpus: .make(threadCount: 3, now: fixedNow), flags: FeatureFlags().with(.menuBarExtra, true))
        await ready(f)
        await eventually(timeout: .seconds(15)) { f.menuBar.isShown }
        _ = f.store.deliverMessage(account: f.account, from: EmailAddress(name: "Sam Sample", email: "sam@x.example"),
                                   subject: "Invoice question", important: true)
        await eventually(timeout: .seconds(15)) { f.menuBar.threads.contains { $0.detail == "Invoice question" } }
        f.env.system.preferences.hidePreviews = true
        await eventually(timeout: .seconds(15)) { !f.menuBar.threads.isEmpty && f.menuBar.threads.allSatisfy { $0.detail.isEmpty } }
        let text = f.menuBar.threads.map { $0.title + $0.detail }.joined()
        #expect(!text.contains("Sam") && !text.contains("Invoice") && !text.contains("sam@"))
        #expect(f.menuBar.threads.allSatisfy { $0.title == NotificationService.hiddenPreviewTitle })
        f.env.system.preferences.hidePreviews = false
        await eventually(timeout: .seconds(15)) { f.menuBar.threads.contains { $0.detail == "Invoice question" } }
    }

    @Test func theInboxSettingListsUnreadConversationsThatAreNotImportantToo() async throws {
        let f = SystemFixture(corpus: .make(threadCount: 3, now: fixedNow), flags: FeatureFlags().with(.menuBarExtra, true))
        await ready(f)
        _ = f.store.deliverMessage(account: f.account, from: EmailAddress(name: "Shop", email: "shop@x.example"), subject: "Sale")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!f.menuBar.threads.contains { $0.detail == "Sale" })
        f.env.system.preferences.menuBarCount = .inbox
        await eventually(timeout: .seconds(15)) { f.menuBar.threads.contains { $0.detail == "Sale" } }
    }

    @Test func theListIsEmptyWhenTheItemIsOffAndGoneWhenSwitchedOff() async throws {
        let f = SystemFixture(corpus: .make(threadCount: 5, now: fixedNow))
        #expect(f.menuBar.threadHistory.isEmpty)
        f.env.system.setMenuBar(enabled: true)
        await eventually(timeout: .seconds(15)) { !f.menuBar.threads.isEmpty }
        f.env.system.setMenuBar(enabled: false)
        #expect(f.menuBar.threads.isEmpty)
    }

    @Test func menuChoicesOpenTheWindowOpenAComposerAndQuit() async throws {
        let f = SystemFixture(flags: FeatureFlags().with(.menuBarExtra, true))
        await ready(f)
        await eventually(timeout: .seconds(15)) { f.menuBar.isShown }
        f.menuBar.choose(.openMail)
        #expect(f.active.windowShows == 1 && f.env.composeIfStarted?.sessions.isEmpty != false)
        f.menuBar.choose(.compose)
        #expect(f.active.windowShows == 2, "the window comes forward before the new message")
        let session = try #require(f.env.composeIfStarted?.sessions.first)
        #expect(session.mode == .new && f.env.compose.sessions.count == 1)
        #expect(f.active.quits == 0)
        f.menuBar.choose(.quit)
        #expect(f.active.quits == 1)
        #expect(f.env.undo?.nextUndo == nil, "nothing was sent or changed")
    }

    @Test func theMenuTitlesComeFromTheCatalog() {
        #expect(MenuBarModel.title(.openMail) == "Open Mail")
        #expect(MenuBarModel.title(.compose) == ActionCatalog.descriptor(.compose)?.title)
        #expect(MenuBarModel.title(.quit) == "Quit Mail")
        #expect(MenuBarSettingsModel.countTitle(.off) == "No number")
        #expect(MenuBarSettingsModel.countTitle(.important) == DockBadgeSource.important.title)
    }

    @Test func theInertPlatformHasNoRealMenuBarOrHotKey() {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow), featureFlags: FeatureFlags())
        #expect(env.system.platform.menuBarItem is FakeMenuBarItem)
        #expect(env.system.platform.hotkeys is FakeGlobalHotkey)
    }

    @Test func preferencesPersistInTheirDefaultsSuite() {
        let suite = "openhuman.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = SystemPreferences(defaults: defaults)
        #expect(!a.menuBarEnabled && a.menuBarCount == .important && !a.globalHotkeyEnabled)
        #expect(a.globalHotkeyBinding == GlobalHotkeyRules.defaultBinding.grammar)
        a.menuBarEnabled = true
        a.menuBarCount = .inbox
        a.globalHotkeyEnabled = true
        a.globalHotkeyBinding = "⌃⌥⌘n"
        let b = SystemPreferences(defaults: defaults)
        #expect(b.menuBarEnabled && b.menuBarCount == .inbox && b.globalHotkeyEnabled && b.globalHotkeyBinding == "⌃⌥⌘n")
        #expect(FeatureFlags.load(from: defaults).isEnabled(.menuBarExtra, default: false))
        #expect(FeatureFlags.load(from: defaults).isEnabled(.globalHotkey, default: false))
    }

    @Test func thePlatformPageOffersTheMenuBarAndShortcutControls() {
        let f = SystemFixture()
        let page = PlatformFeaturesModel(environment: f.env)
        #expect(Set(page.rows.filter(\.isAvailable).map(\.id)) == ["spotlight", "menuBarExtra", "globalHotkey", "services", "appIntents", "focusFilters", "writingTools"])
        #expect(page.menuBar != nil && page.hotkey != nil)
        #expect(page.rows.filter { !$0.isAvailable }.allSatisfy { $0.status.contains("Not in this build yet") })
        let rows = FeaturesSettingsModel(modules: ModuleList.all, registered: f.env.modules.modules,
                                         defaults: f.env.system.preferences.defaults).rows
        #expect(rows.first { $0.id == .menuBarExtra }?.title == "Menu bar item")
        #expect(rows.first { $0.id == .globalHotkey }?.title == "Global shortcut")
        #expect(rows.first { $0.id == .menuBarExtra }?.isOn == false && rows.first { $0.id == .globalHotkey }?.isOn == false)
    }
}

@MainActor
@Suite(.serialized)
struct GlobalHotkeyTests {
    private func ready(_ f: SystemFixture) async {
        f.env.router.start()
        f.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { f.env.router.active?.list?.state == .loaded }
    }

    private func check(_ text: String) -> Result<GlobalHotkey, GlobalHotkeyRules.Problem> {
        switch GlobalHotkeyRules.parse(text) {
        case .success(let binding): GlobalHotkeyRules.hotkey(for: binding)
        case .failure(let problem): .failure(problem)
        }
    }

    @Test func aShortcutIsOneLetterOrDigitWithTwoOfControlOptionCommand() throws {
        #expect(try check("⌃⌥m").get() == GlobalHotkey(key: "M", modifiers: [.control, .option]))
        #expect(try check("ctrl+opt+m").get() == GlobalHotkey(key: "M", modifiers: [.control, .option]))
        #expect(try check("⌃⌥M").get() == GlobalHotkey(key: "M", modifiers: [.control, .option, .shift]), "a capital is typed with ⇧")
        #expect(try check("⌃⌥⇧m").get() == GlobalHotkey(key: "M", modifiers: [.control, .option, .shift]))
        #expect(try check("⌥⌘1").get() == GlobalHotkey(key: "1", modifiers: [.option, .command]))
        #expect(try check("⌃⌥⌘n").get() == GlobalHotkey(key: "N", modifiers: [.control, .option, .command]))
        #expect(check("⌘m") == .failure(.needsTwoModifiers))
        #expect(check("⇧⌘m") == .failure(.needsTwoModifiers), "⇧ does not count")
        #expect(check("m") == .failure(.needsTwoModifiers))
        #expect(check("⌃⌥↵") == .failure(.unsupportedKey))
        #expect(check("⌃⌥#") == .failure(.unsupportedKey))
        #expect(check("⌃⌥é") == .failure(.unsupportedKey), "only keys of the ANSI table")
        #expect(check("g i") == .failure(.sequence))
        #expect(check("⌃⌘s") == .failure(.usedByMail("Label Sidebar")), "Mail's own ⌃⌘S would stop working while it is in front")
        for text in ["pageup", "", "⌘"] {
            guard case .failure(.unreadable) = check(text) else {
                Issue.record("\"\(text)\" should be unreadable")
                continue
            }
        }
    }

    @Test func theDefaultIsValidAndCollidesWithNothingInTheCatalog() throws {
        let hotkey = try GlobalHotkeyRules.hotkey(for: GlobalHotkeyRules.defaultBinding).get()
        #expect(hotkey.description == "⌃⌥M")
        #expect(GlobalHotkeyRules.defaultBinding.grammar == "⌃⌥m")
        #expect(!ActionCatalog.all.contains { $0.defaultBindings.contains { $0.chords == GlobalHotkeyRules.defaultBinding.chords } })
    }

    @Test func everyProblemSaysWhatToDo() {
        let problems: [GlobalHotkeyRules.Problem] = [.unreadable("x"), .sequence, .unsupportedKey, .needsTwoModifiers,
                                                     .usedByMail("Label Sidebar")]
        #expect(problems.allSatisfy { !$0.description.isEmpty && $0.description.hasSuffix(".") })
    }

    @Test func offByDefaultSoNoKeyIsRegistered() async throws {
        let f = SystemFixture()
        f.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { f.env.system.notifications != nil }
        #expect(f.env.system.globalHotkey == nil && f.hotkeys.registered == nil && f.hotkeys.history.isEmpty)
        #expect(!f.env.modules.modules.contains(.globalHotkey))
    }

    @Test func flagOnAtLaunchRegistersOnceAndAPressOpensANewMessage() async throws {
        let f = SystemFixture(flags: FeatureFlags().with(.globalHotkey, true))
        await ready(f)
        f.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { f.hotkeys.registered != nil }
        #expect(f.hotkeys.registered == GlobalHotkey(key: "M", modifiers: [.control, .option]))
        #expect(f.hotkeys.history.count == 1)
        #expect(f.env.system.globalHotkey?.isRegistered == true)
        f.hotkeys.press()
        #expect(f.active.windowShows == 1, "Mail comes forward")
        let session = try #require(f.env.composeIfStarted?.sessions.first)
        #expect(session.mode == .new)
        #expect(f.env.undo?.nextUndo == nil, "a press only opens a composer")
    }

    @Test func theSwitchRegistersAndDropsAtOnceAndIsRemembered() async throws {
        let f = SystemFixture()
        let settings = GlobalHotkeySettingsModel(system: f.env.system)
        #expect(!settings.isOn && settings.current == "⌃⌥M" && settings.draft == "⌃⌥m")
        #expect(settings.status == "Off. ⌃⌥M does nothing.")
        settings.setOn(true)
        #expect(settings.isOn && f.hotkeys.registered != nil)
        #expect(settings.status == "⌃⌥M opens a new message.")
        #expect(FeatureFlags.load(from: f.env.system.preferences.defaults).isEnabled(.globalHotkey, default: false))
        settings.setOn(false)
        #expect(!settings.isOn && f.hotkeys.registered == nil && f.hotkeys.unregisterCalls >= 1)
        #expect(!FeatureFlags.load(from: f.env.system.preferences.defaults).isEnabled(.globalHotkey, default: false))
        f.hotkeys.press()
        #expect(f.active.windowShows == 0, "an unregistered shortcut does nothing")
    }

    @Test func newKeysReplaceTheRegistrationAndAreRemembered() async throws {
        let f = SystemFixture()
        f.env.system.setGlobalHotkey(enabled: true)
        let settings = GlobalHotkeySettingsModel(system: f.env.system)
        settings.draft = "ctrl+opt+cmd+n"
        settings.apply()
        #expect(settings.problem == nil && settings.draft == "⌃⌥⌘n")
        #expect(f.hotkeys.registered == GlobalHotkey(key: "N", modifiers: [.control, .option, .command]))
        #expect(f.env.system.preferences.globalHotkeyBinding == "⌃⌥⌘n")
        settings.draft = "⌘n"
        settings.apply()
        #expect(settings.problem == GlobalHotkeyRules.Problem.needsTwoModifiers.description)
        #expect(f.hotkeys.registered?.key == "N" && f.env.system.preferences.globalHotkeyBinding == "⌃⌥⌘n")
        let next = GlobalHotkeyModel(registrar: FakeGlobalHotkey(), preferences: f.env.system.preferences) {}
        #expect(next.display == "⌃⌥⌘N")
    }

    @Test func theFieldsTextReadsBackAsTheSameShortcut() async throws {
        let f = SystemFixture()
        f.env.system.setGlobalHotkey(enabled: true)
        let settings = GlobalHotkeySettingsModel(system: f.env.system)
        let registered = f.hotkeys.registered
        let calls = f.hotkeys.history.count
        settings.apply()
        #expect(settings.problem == nil && f.hotkeys.registered == registered && f.hotkeys.history.count == calls)
        #expect(f.env.system.preferences.globalHotkeyBinding == "⌃⌥m")
        #expect(!GlobalHotkeySettingsModel.note.contains("ctrl+") && !GlobalHotkeySettingsModel.note.contains("⌃⌥m"))
        for text in ["⌃⌥m", "⌃⌥⇧m", "⌥⌘1", "ctrl+opt+cmd+n"] {
            let binding = try GlobalHotkeyRules.parse(text).get()
            settings.draft = text
            settings.apply()
            #expect(try GlobalHotkeyRules.parse(settings.draft).get() == binding, "\(text) shows as \(settings.draft)")
        }
    }

    @Test func recordedKeysAreCheckedAndStoredLikeTypedOnes() async throws {
        #expect(GlobalHotkeyRules.recorded(key: "m", modifiers: [.control, .option]) == .chord("m", [.control, .option]))
        #expect(GlobalHotkeyRules.recorded(key: "m", modifiers: [.control, .option, .shift])?.description == "⌃⌥⇧M")
        #expect(GlobalHotkeyRules.recorded(key: "M", modifiers: [.control, .option])?.grammar == "⌃⌥m", "Caps Lock adds no ⇧")
        #expect(GlobalHotkeyRules.recorded(key: "1", modifiers: [.control, .option, .shift])?.grammar == "⌃⌥⇧1")
        for key in ["\r", "\t", " ", "", "ab", "é"] {
            #expect(GlobalHotkeyRules.recorded(key: key, modifiers: [.control, .option]) == nil, "\(key.debugDescription)")
        }
        let f = SystemFixture()
        f.env.system.setGlobalHotkey(enabled: true)
        let settings = GlobalHotkeySettingsModel(system: f.env.system)
        settings.record(key: "k", modifiers: [.control, .command])
        #expect(settings.problem == nil && settings.current == "⌃⌘K" && settings.draft == "⌃⌘k")
        #expect(f.hotkeys.registered == GlobalHotkey(key: "K", modifiers: [.control, .command]))
        #expect(f.env.system.preferences.globalHotkeyBinding == "⌃⌘k")
        settings.record(key: "n", modifiers: [.command])
        #expect(settings.problem == GlobalHotkeyRules.Problem.needsTwoModifiers.description)
        #expect(settings.current == "⌃⌘K" && settings.draft == "⌃⌘k", "a refused press keeps the keys in use")
        settings.record(key: "\t", modifiers: [.control, .option])
        #expect(settings.problem == GlobalHotkeyRules.Problem.unsupportedKey.description)
        #expect(f.hotkeys.registered?.key == "K" && f.env.system.preferences.globalHotkeyBinding == "⌃⌘k")
    }

    @Test func keysSetWhileOffAreStoredAndUsedWhenSwitchedOn() async throws {
        let f = SystemFixture()
        let settings = GlobalHotkeySettingsModel(system: f.env.system)
        settings.draft = "⌥⌘1"
        settings.apply()
        #expect(settings.problem == nil && f.hotkeys.registered == nil)
        #expect(settings.current == "⌥⌘1")
        settings.setOn(true)
        #expect(f.hotkeys.registered == GlobalHotkey(key: "1", modifiers: [.option, .command]))
    }

    @Test func aRefusalIsShownAndOtherKeysTryAgainAtOnce() async throws {
        let f = SystemFixture()
        f.hotkeys.failure = .refused(-9878)
        let settings = GlobalHotkeySettingsModel(system: f.env.system)
        settings.setOn(true)
        let model = try #require(f.env.system.globalHotkey)
        #expect(settings.isOn && !model.isRegistered && f.hotkeys.registered == nil)
        #expect(settings.status.contains("didn't accept ⌃⌥M") && settings.status.contains("-9878"))
        f.hotkeys.failure = nil
        settings.draft = "⌃⌥k"
        settings.apply()
        #expect(model.isRegistered && model.errorMessage == nil)
        #expect(f.hotkeys.registered == GlobalHotkey(key: "K", modifiers: [.control, .option]))
    }

    @Test func storedTextThatIsNotAShortcutFallsBackToTheDefault() {
        let f = SystemFixture()
        f.env.system.preferences.globalHotkeyBinding = "⌘q"
        #expect(GlobalHotkeyModel(registrar: f.hotkeys, preferences: f.env.system.preferences) {}.display == "⌃⌥M")
        f.env.system.preferences.globalHotkeyBinding = "not a key"
        #expect(GlobalHotkeyModel.binding(stored: f.env.system.preferences.globalHotkeyBinding) == GlobalHotkeyRules.defaultBinding)
    }
}
