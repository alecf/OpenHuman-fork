import AppKit
import MailActions
import MailFeatures
import Testing
@testable import MailUIMac

@MainActor
struct KeymapHintsFollowUserTests {
    private func registry(_ overrides: [String: [String]]) -> ActionRegistry {
        let registry = ActionRegistry()
        registry.applyKeymap(KeymapOverrides(bindings: overrides))
        return registry
    }

    @Test func menuHintsShowTheUsersKeyAndReadTheRegistryEachTimeAMenuOpens() throws {
        let registry = ActionRegistry()
        let title = try #require(ActionCatalog.descriptor(.markDone)?.title)
        let hints = MenuShortcutHints(source: { registry.descriptors })
        #expect(hints.hint(for: title) == "E", "the standard key")
        registry.applyKeymap(KeymapOverrides(bindings: [ActionID.markDone.rawValue: ["g 9"]]))
        #expect(registry.keymap.issues.isEmpty)
        let expected = try KeyBinding(parsing: "g 9").description
        #expect(hints.hint(for: title) == expected, "the same object now shows the user's key")
        #expect(MenuShortcutHints(descriptors: ActionCatalog.all).hint(for: title) == "E")
        #expect(MenuShortcutHints(descriptors: registry.descriptors).hint(for: title) == expected)
    }

    @Test func menuItemsGetTheUsersHintAttached() throws {
        let registry = registry([ActionID.markDone.rawValue: ["g 9"]])
        let title = try #require(ActionCatalog.descriptor(.markDone)?.title)
        let menu = NSMenu(title: "Test")
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        MenuShortcutHints(source: { registry.descriptors }).apply(to: menu)
        let shown = try #require(menu.items.first?.attributedTitle?.string)
        #expect(shown == title + "\t" + (try KeyBinding(parsing: "g 9").description))
    }

    @Test func aKeylessActionGivenAKeyShowsItInTheMenu() throws {
        let registry = registry([ActionID.notSpam.rawValue: ["g 8"]])
        let title = try #require(ActionCatalog.descriptor(.notSpam)?.title)
        #expect(MenuShortcutHints(descriptors: ActionCatalog.all).hint(for: title) == nil)
        #expect(MenuShortcutHints(source: { registry.descriptors }).hint(for: title) == (try KeyBinding(parsing: "g 8").description))
    }

    @Test func theComposerKeyTableFollowsTheKeymap() throws {
        let standard = KeyTable.composer(ActionCatalog.all)
        let sendChord = try #require(standard.first { $0.value == .send }?.key)
        let registry = registry([ActionID.send.rawValue: ["⌥⌘9"]])
        #expect(registry.keymap.issues.isEmpty, "\(registry.keymap.issues)")
        let table = KeyTable.composer(registry.descriptors)
        #expect(table[sendChord] == nil, "the old chord does nothing")
        let moved = KeyChord(.character("9"), modifiers: [.command, .option])
        #expect(table[moved] == .send)
    }
}
