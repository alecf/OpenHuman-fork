import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct GapsAKeyTests {
    @Test func theKeysAreCatalogEntries() throws {
        func keys(_ id: ActionID) -> [String]? { ActionCatalog.descriptor(id)?.defaultBindings.map(\.description) }
        #expect(keys(.goSnippets) == ["G ;"])
        #expect(keys(.composeRemind) == ["⇧⌘H"])
        #expect(keys(.toggleFormatBar) == ["⌥⌘F"])
        let snippets = try #require(ActionCatalog.descriptor(.goSnippets))
        #expect(snippets.effect == .view && snippets.category == .navigation && snippets.module == nil)
        let remind = try #require(ActionCatalog.descriptor(.composeRemind))
        #expect(remind.scopes == [.composer] && remind.changesMail && remind.module == .reminders)
        #expect(ActionCatalog.descriptor(.toggleFormatBar)?.scopes == [.composer])
        #expect(PaletteController.symbol(for: .goSnippets) == "text.insert")
        #expect(PaletteController.symbol(for: .composeRemind) == "bell")
    }

    @Test func gSemicolonOpensSettingsAtSnippets() async {
        let f = ActionFixture()
        await f.loaded()
        #expect(f.registry.availability(.goSnippets, host: f.router) == .hidden, "nothing can open the window yet")
        var opened = 0
        f.env.settingsNavigator.openWindow = { opened += 1 }
        #expect(f.registry.availability(.goSnippets, host: f.router) == .enabled)
        #expect(await f.run(.goSnippets))
        #expect(opened == 1)
        #expect(f.env.settingsNavigator.takeRequestedPage() == "snippets")
    }

    @Test func shiftCommandHInADraftOpensItsRemindPicker() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        #expect(f.env.actions.availability(.composeRemind, host: session) == .enabled)
        #expect(await f.run(.composeRemind, in: session))
        let picker = try #require(f.timePicker)
        #expect(picker.kind == .remind && picker.onlyIfNoReply, "the bar's Remind me, a follow-up by default")
        #expect(picker.chooseNumber(1))
        #expect(session.pendingReminder != nil, "kept with the draft until the send commits")
    }

    @Test func shiftCommandHIsGoneWithRemindersOff() async throws {
        let off = ComposeFixture(flags: FeatureFlags().with(.reminders, false))
        await off.loaded()
        let draft = try #require(off.compose.openNew(placement: .modal))
        #expect(off.env.actions.availability(.composeRemind, host: draft) == .hidden)
    }

    @Test func optionCommandFTogglesTheFormattingBar() async throws {
        let f = ComposeFixture()
        await f.loaded()
        await f.compose.settle()
        let session = try #require(f.compose.openNew(placement: .modal))
        let before = f.compose.showsFormatBar
        #expect(await f.run(.toggleFormatBar, in: session))
        #expect(f.compose.showsFormatBar != before)
    }
}
