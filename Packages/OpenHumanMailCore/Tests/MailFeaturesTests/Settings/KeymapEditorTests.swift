import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct KeymapEditorTests {
    private func make(_ stored: KeymapOverrides? = nil) -> (ActionRegistry, InMemoryKeymapStore, KeymapEditorModel) {
        let registry = ActionRegistry()
        if let stored { registry.applyKeymap(stored) }
        let store = InMemoryKeymapStore(stored)
        return (registry, store, KeymapEditorModel(registry: registry, store: store))
    }

    private func chord(_ text: String) throws -> KeyBinding.Chord {
        try #require(try KeyBinding(parsing: text).chords.first)
    }

    private func firstKey(_ registry: ActionRegistry, _ id: ActionID) -> String? {
        registry.descriptor(id)?.defaultBindings.first?.grammar
    }

    @Test func aFreeKeyBecomesTheFirstKeyAndIsStoredAndApplied() throws {
        let (registry, store, editor) = make()
        editor.startRecording(.markDone)
        #expect(editor.recording == .markDone)
        #expect(editor.record(try chord("⌥⌘9")) == .changed)
        #expect(editor.recording == nil)
        #expect(firstKey(registry, .markDone) == "⌥⌘9")
        #expect(store.load()?.bindings[ActionID.markDone.rawValue] == ["⌥⌘9"])
        #expect(editor.isCustomized(.markDone))
        #expect(editor.message?.contains("⌥⌘9") == true && !editor.messageIsRefusal)
        #expect(registry.keymap.issues.isEmpty)
    }

    @Test func aKeyAnotherActionUsesIsRefusedWithItsName() throws {
        let (registry, store, editor) = make()
        let trash = try #require(ActionCatalog.descriptor(.trash))
        let trashKey = try #require(trash.defaultBindings.first)
        editor.startRecording(.markDone)
        let outcome = editor.record(try #require(trashKey.chords.first))
        guard case .refused(let reason) = outcome else { throw TestFailure("accepted: \(outcome)") }
        #expect(reason.contains(trash.title), "\(reason)")
        #expect(editor.messageIsRefusal)
        #expect(firstKey(registry, .markDone) == "e", "nothing changed")
        #expect(store.load() == nil, "nothing stored")
    }

    @Test func theFixedKeysAndThePaletteKeyCannotBeTaken() throws {
        let (registry, _, editor) = make()
        editor.startRecording(.markDone)
        guard case .refused(let reason) = editor.record(try chord("⌘q")) else { throw TestFailure("⌘Q was accepted") }
        #expect(reason.contains("Quit Mail"))
        #expect(firstKey(registry, .markDone) == "e")
        #expect(!editor.canChange(.commandPalette))
        editor.startRecording(.commandPalette)
        #expect(editor.recording == nil)
    }

    @Test func gStaysAPrefixAndASequenceTakesTwoKeys() throws {
        let (registry, _, editor) = make()
        editor.startRecording(.markDone)
        #expect(editor.record(try chord("g")) == .waitingForSecondKey)
        #expect(editor.pendingText == "G…")
        guard case .refused = editor.finishPending() else { throw TestFailure("g alone was accepted") }
        #expect(firstKey(registry, .markDone) == "e")

        editor.startRecording(.markDone)
        _ = editor.record(try chord("g"))
        #expect(editor.record(try chord("9")) == .changed)
        #expect(firstKey(registry, .markDone) == "g 9")
    }

    @Test func escCancelsWithoutChangingAnything() throws {
        let (registry, store, editor) = make()
        editor.startRecording(.markDone)
        #expect(editor.record(KeyBinding.Chord(.named(.escape))) == .cancelled)
        #expect(editor.recording == nil && store.load() == nil)
        #expect(firstKey(registry, .markDone) == "e")
        #expect(editor.record(try chord("x")) == .notRecording)
    }

    @Test func changingTheFirstKeyKeepsTheOthers() throws {
        let (registry, _, editor) = make()
        let before = try #require(registry.descriptor(.nextThread)).defaultBindings
        #expect(editor.assign(try KeyBinding(parsing: "⌥⌘8"), to: .nextThread) == .changed)
        let after = try #require(registry.descriptor(.nextThread)).defaultBindings
        #expect(after.count == before.count)
        #expect(after.first?.grammar == "⌥⌘8")
        #expect(Array(after.dropFirst().map(\.chords)) == Array(before.dropFirst().map(\.chords)))
    }

    @Test func resetPutsTheStandardKeyBackAndResetAllClearsEverything() throws {
        let (registry, store, editor) = make()
        #expect(editor.assign(try KeyBinding(parsing: "⌥⌘9"), to: .markDone) == .changed)
        #expect(editor.assign(try KeyBinding(parsing: "⌥⌘8"), to: .trash) == .changed)
        #expect(editor.reset(.markDone) == .changed)
        #expect(firstKey(registry, .markDone) == "e")
        #expect(!editor.isCustomized(.markDone) && editor.isCustomized(.trash))
        editor.resetAll()
        #expect(registry.keymap.overrides.isEmpty)
        #expect(store.load()?.isEmpty == true)
        #expect(!editor.isCustomized(.trash))
    }

    @Test func resetIsRefusedWhileAnotherActionHoldsTheStandardKey() throws {
        let (registry, _, editor) = make()
        #expect(editor.assign(try KeyBinding(parsing: "⌥⌘9"), to: .markDone) == .changed)
        #expect(editor.assign(try KeyBinding(parsing: "e"), to: .trash) == .changed, "E is free once Mark done moved")
        guard case .refused = editor.reset(.markDone) else { throw TestFailure("reset took E back from Trash") }
        #expect(firstKey(registry, .trash) == "e")
        #expect(firstKey(registry, .markDone) == "⌥⌘9")
    }

    @Test func theKeymapFileRoundTripsAndItsImportPreviewsThenReplaces() throws {
        let (_, _, source) = make()
        #expect(source.assign(try KeyBinding(parsing: "⌥⌘9"), to: .markDone) == .changed)
        let data = try source.exportData()

        let (registry, store, editor) = make()
        let preview = try editor.importPreview(data)
        #expect(preview.changedCount == 1 && preview.refused.isEmpty)
        #expect(firstKey(registry, .markDone) == "e", "a preview changes nothing")
        editor.applyImport(preview)
        #expect(firstKey(registry, .markDone) == "⌥⌘9")
        #expect(store.load()?.bindings[ActionID.markDone.rawValue] == ["⌥⌘9"])
    }

    @Test func anImportedLineThatConflictsIsSkippedAndSaid() throws {
        let (registry, _, editor) = make()
        let file = KeymapOverrides(bindings: [ActionID.markDone.rawValue: ["⌥⌘9"], ActionID.trash.rawValue: ["⌘q"],
                                              "no.suchAction": ["x"]])
        let preview = try editor.importPreview(try JSONEncoder().encode(file))
        #expect(preview.changedCount == 1)
        #expect(preview.refused.count == 2, "\(preview.refused)")
        editor.applyImport(preview)
        #expect(firstKey(registry, .markDone) == "⌥⌘9")
        #expect(registry.descriptor(.trash)?.defaultBindings == ActionCatalog.descriptor(.trash)?.defaultBindings)
        #expect(throws: KeymapFileError.self) { try editor.importPreview(Data("not json".utf8)) }
        let future = KeymapOverrides(version: 9, bindings: [:])
        #expect(throws: KeymapFileError.unsupportedVersion(9)) { try editor.importPreview(try JSONEncoder().encode(future)) }
    }

    @Test func theRecorderReadsKeysAsTheGrammarDoes() {
        #expect(KeyRecorder.chord(keyCode: 14, characters: "E", command: false, option: false, control: false, shift: true)
                == KeyBinding.Chord(.character("E")))
        #expect(KeyRecorder.chord(keyCode: 26, characters: "&", command: true, option: false, control: false, shift: true)
                == KeyBinding.Chord(.character("7"), modifiers: [.command, .shift]))
        #expect(KeyRecorder.chord(keyCode: 36, characters: "\r", command: false, option: false, control: false, shift: false)
                == KeyBinding.Chord(.named(.enter)))
        #expect(KeyRecorder.chord(keyCode: 49, characters: " ", command: false, option: false, control: false,
                                  shift: false) == nil, "the space bar has no name in the grammar")
        #expect(KeyRecorder.chord(keyCode: 122, characters: "\u{F704}", command: false, option: false, control: false,
                                  shift: false) == nil, "function keys are not recorded")
    }

    @Test func theStoredKeymapAppliesAtLaunchAndTheShortcutsPageShowsIt() throws {
        let store = InMemoryKeymapStore(KeymapOverrides(bindings: [ActionID.markDone.rawValue: ["⌥⌘9"]]))
        let env = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow), keymapStore: store)
        #expect(env.actions.descriptor(.markDone)?.defaultBindings.first?.grammar == "⌥⌘9")
        let model = ShortcutsSettingsModel(environment: env)
        let line = model.sections.flatMap(\.lines).first { $0.action == .markDone }
        #expect(line?.keys.first == "⌥⌘9")
        #expect(model.editor?.isCustomized(.markDone) == true)
        #expect(model.editor?.reset(.markDone) == .changed)
        let after = model.sections.flatMap(\.lines).first { $0.action == .markDone }
        #expect(after?.keys.first == "E")
    }
}
