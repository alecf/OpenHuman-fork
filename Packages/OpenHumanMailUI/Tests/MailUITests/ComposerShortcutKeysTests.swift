#if os(macOS)
import MailActions
import SwiftUI
import Testing
@testable import MailUI

@MainActor
@Suite struct ComposerShortcutKeysTests {
    @Test func theFormatBarAndRemindKeysAreHiddenComposerButtons() {
        let items = ComposerShortcuts.shortcuts(ActionCatalog.all)
        let bar = items.filter { $0.action == .toggleFormatBar }
        #expect(bar.count == 1)
        #expect(bar.first?.shortcut.key == KeyEquivalent("f") && bar.first?.shortcut.modifiers == [.command, .option])
        let remind = items.filter { $0.action == .composeRemind }
        #expect(remind.count == 1)
        #expect(remind.first?.shortcut.key == KeyEquivalent("h") && remind.first?.shortcut.modifiers == [.command, .shift])
        for id in ActionCatalog.formatIDs { #expect(!items.contains { $0.action == id }, "\(id) is the body's own") }
    }
}
#endif
