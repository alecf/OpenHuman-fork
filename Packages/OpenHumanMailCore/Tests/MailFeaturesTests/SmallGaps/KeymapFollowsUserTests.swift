import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct KeymapFollowsUserTests {
    private func chord(_ text: String) throws -> KeyBinding.Chord {
        try #require(try KeyBinding(parsing: text).chords.first)
    }

    @Test func theGlobalShortcutCheckReadsTheUsersKeysNotTheDefaults() throws {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow))
        #expect(try GlobalHotkeyRules.parse("⌃⌥⌘9", catalog: env.system.effectiveCatalog).get().grammar == "⌃⌥⌘9")
        env.actions.applyKeymap(KeymapOverrides(bindings: [ActionID.markDone.rawValue: ["⌃⌥⌘9"]]))
        #expect(env.actions.keymap.issues.isEmpty)
        let title = try #require(ActionCatalog.descriptor(.markDone)?.title)
        #expect(GlobalHotkeyRules.parse("⌃⌥⌘9", catalog: env.system.effectiveCatalog) == .failure(.usedByMail(title)))
        #expect(GlobalHotkeyRules.parse("⌃⌥⌘9") != .failure(.usedByMail(title)), "the standard catalog does not know it")
    }

    @Test func aKeyTheUserFreedCanBeTheGlobalShortcutAndTheSettingsModelUsesTheEffectiveKeys() throws {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow))
        let sidebar = try #require(ActionCatalog.descriptor(.toggleLabelSidebar))
        let oldKey = try #require(sidebar.defaultBindings.first)
        #expect(GlobalHotkeyRules.parse(oldKey.grammar, catalog: env.system.effectiveCatalog)
                    == .failure(.usedByMail(sidebar.title)))
        env.actions.applyKeymap(KeymapOverrides(bindings: [ActionID.toggleLabelSidebar.rawValue: ["⌥⌘9"]]))
        #expect(env.actions.keymap.issues.isEmpty)
        #expect(!env.system.effectiveCatalog.contains { $0.defaultBindings.contains { $0.chords == oldKey.chords } })
        let settings = GlobalHotkeySettingsModel(system: env.system)
        settings.draft = oldKey.grammar
        settings.apply()
        #expect(settings.problem == nil, "\(String(describing: settings.problem))")
        env.actions.applyKeymap(KeymapOverrides(bindings: [ActionID.markDone.rawValue: ["⌃⌥⌘9"]]))
        settings.draft = "⌃⌥⌘9"
        settings.apply()
        #expect(settings.problem == GlobalHotkeyRules.Problem.usedByMail("Mark done").description)
    }

    @Test func theRunningModelChecksNewKeysAgainstTheRegistryCatalog() throws {
        let f = SystemFixture()
        f.env.actions.applyKeymap(KeymapOverrides(bindings: [ActionID.markDone.rawValue: ["⌃⌥⌘9"]]))
        let model = GlobalHotkeyModel(registrar: f.hotkeys, preferences: f.env.system.preferences,
                                      catalog: { f.env.system.effectiveCatalog }) {}
        let title = try #require(f.env.actions.descriptor(.markDone)?.title)
        #expect(model.change(to: "⌃⌥⌘9") == .usedByMail(title))
        #expect(model.change(to: "⌃⌥⌘8") == nil)
        let standard = GlobalHotkeyModel(registrar: FakeGlobalHotkey(), preferences: f.env.system.preferences) {}
        #expect(standard.change(to: "⌃⌥⌘9") == nil)
    }

    private func make() -> (ActionRegistry, InMemoryKeymapStore, KeymapEditorModel) {
        let registry = ActionRegistry()
        let store = InMemoryKeymapStore()
        return (registry, store, KeymapEditorModel(registry: registry, store: store))
    }

    @Test func aKeylessActionGetsAFreeKeyStoredAndApplied() throws {
        let (registry, store, editor) = make()
        #expect(registry.descriptor(.notSpam)?.defaultBindings.isEmpty == true, "the premise: Not spam has no key")
        #expect(editor.canChange(.notSpam))
        editor.startRecording(.notSpam)
        #expect(editor.record(try chord("⌥⌘9")) == .changed)
        #expect(registry.descriptor(.notSpam)?.defaultBindings.map(\.grammar) == ["⌥⌘9"])
        #expect(store.load()?.bindings[ActionID.notSpam.rawValue] == ["⌥⌘9"])
        #expect(registry.keymap.issues.isEmpty)
        #expect(ShortcutSheet(descriptors: registry.descriptors).sections.flatMap(\.lines).contains {
            $0.action == .notSpam && $0.keys == ["⌥⌘9"]
        }, "it now shows in the list of keys")
        #expect(editor.reset(.notSpam) == .changed)
        #expect(registry.descriptor(.notSpam)?.defaultBindings.isEmpty == true)
        #expect(!editor.isCustomized(.notSpam))
    }

    @Test func aKeylessActionRefusesAKeyAnotherActionUsesAndTheFixedKeys() throws {
        let (registry, store, editor) = make()
        let markDone = try #require(ActionCatalog.descriptor(.markDone))
        editor.startRecording(.notSpam)
        guard case .refused(let reason) = editor.record(try #require(markDone.defaultBindings.first?.chords.first)) else {
            throw TestFailure("a taken key was accepted")
        }
        #expect(reason.contains(markDone.title), "\(reason)")
        #expect(registry.descriptor(.notSpam)?.defaultBindings.isEmpty == true)
        #expect(store.load() == nil)
        editor.startRecording(.notSpam)
        guard case .refused(let fixed) = editor.record(try chord("⌘q")) else { throw TestFailure("⌘Q was accepted") }
        #expect(fixed.contains("Quit Mail"))
        editor.startRecording(.notSpam)
        #expect(editor.record(try chord("g")) == .waitingForSecondKey)
        #expect(editor.record(try chord("9")) == .changed)
        #expect(registry.descriptor(.notSpam)?.defaultBindings.map(\.grammar) == ["g 9"])
    }

    @Test func theShortcutsPageListsTheKeylessActionsAndDropsOneOnceItHasAKey() throws {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow))
        let page = ShortcutsSettingsModel(environment: env)
        let editor = try #require(page.editor)
        let keyless = page.unassignedLines
        let line = try #require(keyless.first { $0.action == .notSpam })
        #expect(line.keys.isEmpty && line.title == "Not spam")
        #expect(!keyless.contains { $0.action == .markDone }, "an action with a key is not listed")
        #expect(!keyless.contains { $0.action == .commandPalette })
        #expect(keyless.allSatisfy { editor.canChange($0.action) })
        page.searchText = "not spam"
        #expect(page.unassignedLines.map(\.action) == [.notSpam])
        page.searchText = "zzzz"
        #expect(page.unassignedLines.isEmpty)
        page.searchText = ""
        editor.startRecording(.notSpam)
        #expect(editor.record(try chord("⌥⌘9")) == .changed)
        #expect(!page.unassignedLines.contains { $0.action == .notSpam })
        #expect(page.sections.flatMap(\.lines).contains { $0.action == .notSpam && $0.keys == ["⌥⌘9"] })
        #expect(ShortcutsSettingsModel(descriptors: ActionCatalog.all).unassignedLines.isEmpty)
    }
}
