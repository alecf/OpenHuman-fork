import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailActions

@Suite struct GapsDCatalogTests {
    private func resolve(_ id: ActionID, _ text: String) -> Keymap {
        Keymap.resolve(KeymapOverrides(bindings: [id.rawValue: [text]]), descriptors: ActionCatalog.all)
    }

    @Test(arguments: ["⌘q", "⌘w", "⌘h", "⌘m", "⌘,", "cmd+q"])
    func theAppsFixedKeysAreRefused(_ text: String) {
        let keymap = resolve(.markDone, text)
        #expect(keymap.overrides[.markDone] == nil, "\(text) must stay the app's")
        #expect(keymap.issues.contains { issue in
            if case .fixedKey(.markDone, _, _) = issue { true } else { false }
        }, "\(keymap.issues)")
    }

    @Test func aFixedKeyAsASequencesFirstKeyIsRefusedToo() {
        let keymap = resolve(.markDone, "⌘q x")
        #expect(keymap.overrides[.markDone] == nil)
    }

    @Test func aFreeChordIsStillAccepted() throws {
        let keymap = resolve(.markDone, "⌥⌘9")
        #expect(keymap.overrides[.markDone]?.map(\.grammar) == ["⌥⌘9"])
        #expect(keymap.issues.isEmpty)
    }

    @Test func noCatalogKeyIsAFixedKey() {
        for descriptor in ActionCatalog.all {
            for binding in descriptor.defaultBindings {
                #expect(Keymap.fixedUse(of: binding) == nil, "\(descriptor.id): \(binding)")
            }
        }
    }

    @Test func theNewEntriesArePaletteOnlyAndFree() throws {
        #expect(KeyBindingConflicts.find(in: ActionCatalog.all).isEmpty)
        for id in [ActionID.goAllInboxes, .suggestCleanup, .archiveSuggested] {
            let descriptor = try #require(ActionCatalog.descriptor(id))
            #expect(!descriptor.appearsInMenu && descriptor.appearsInPalette, "\(id)")
        }
        #expect(ActionCatalog.descriptor(.goAllInboxes)?.shortcutHint == "⌃0")
        #expect(ActionCatalog.descriptor(.goAllInboxes)?.changesMail == false, "a view")
        #expect(ActionCatalog.descriptor(.suggestCleanup)?.changesMail == false, "it only counts")
        #expect(ActionCatalog.descriptor(.archiveSuggested)?.changesMail == true)
        #expect(ActionCatalog.descriptor(.archiveSuggested)?.module == .hygiene)
        #expect(ActionCatalog.descriptor(.archiveSuggested)?.shortcutHint == "⌥⌘E")
    }
}
