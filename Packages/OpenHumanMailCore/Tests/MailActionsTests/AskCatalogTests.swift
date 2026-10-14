import Testing
@testable import MailActions

@Test func cmdJIsAskAIOutsideTheComposerAndTheRewriteInIt() throws {
    let ask = try #require(ActionCatalog.descriptor(.aiAskInbox))
    let rewrite = try #require(ActionCatalog.descriptor(.aiRewrite))
    #expect(ask.shortcutHint == "⌘J" && rewrite.shortcutHint == "⌘J")
    #expect(ask.scopes == [.list, .reader] && rewrite.scopes == [.composer])
    #expect(ask.scopes.isDisjoint(with: rewrite.scopes))
    #expect(!ask.scopes.contains(.global) && !rewrite.scopes.contains(.global), "a global ⌘J would overlap every scope")
    #expect(ask.module == .ai && ask.effect == .view && !ask.changesMail, "read-only safe mode allows it")
    #expect(ask.appearsInPalette && !ask.appearsInMenu && ask.cliCommand == nil)
    #expect(!ask.activeWhileTyping, "the search field and the Ask field handle ⌘J themselves")
    #expect(KeyBindingConflicts.find(in: ActionCatalog.all).isEmpty)
    #expect(ActionCatalog.descriptors(module: .ai).map(\.id).contains(.aiAskInbox))
}
