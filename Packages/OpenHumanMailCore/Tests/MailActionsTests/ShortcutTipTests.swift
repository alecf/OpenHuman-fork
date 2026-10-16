import Testing
@testable import MailActions

@Suite struct ShortcutTipTests {
    @Test func anActionShowsItsTitleAndOneKeycapPerKey() throws {
        let attach = try #require(ShortcutTip.action(.attachFiles, in: ActionCatalog.all, hint: "(or drag ’n’ drop files)"))
        #expect(attach.title == "Attach files")
        #expect(attach.keycaps == ["⌘", "shift", "U"])
        #expect(attach.hint == "(or drag ’n’ drop files)")
        let discard = try #require(ShortcutTip.action(.discardDraft, in: ActionCatalog.all, title: "Discard"))
        #expect(discard.title == "Discard" && discard.keycaps == ["⌘", "⌫"] && discard.hint == nil)
        #expect(ShortcutTip.action(.send, in: ActionCatalog.all)?.keycaps == ["⌘", "↵"])
        #expect(ShortcutTip.action(.markDone, in: ActionCatalog.all)?.keycaps == ["E"])
        #expect(ShortcutTip.action(.toggleLabelSidebar, in: ActionCatalog.all)?.keycaps == ["⌃", "⌘", "S"])
    }

    @Test func aReboundActionShowsItsNewKeys() {
        let rebound = ActionCatalog.all.map { $0.id == .attachFiles ? $0.rebound([.chord("y", [.option, .command])]) : $0 }
        #expect(ShortcutTip.action(.attachFiles, in: rebound)?.keycaps == ["⌥", "⌘", "Y"])
        let sequence = ActionCatalog.all.map { $0.id == .attachFiles ? $0.rebound([.sequence("g", "a")]) : $0 }
        #expect(ShortcutTip.action(.attachFiles, in: sequence)?.keycaps == ["G", "A"])
    }

    @Test func anUnboundActionShowsNoKeys() throws {
        let unbound = ActionCatalog.all.map { $0.id == .attachFiles ? $0.rebound([]) : $0 }
        let tip = try #require(ShortcutTip.action(.attachFiles, in: unbound, title: "Attach"))
        #expect(tip.title == "Attach" && tip.keycaps.isEmpty)
        let popOut = try #require(ShortcutTip.action(.popOutComposer, in: ActionCatalog.all))
        #expect(popOut.title == "Pop out composer" && popOut.keycaps.isEmpty)
    }

    @Test func aMissingActionHasNoTipUnlessTheButtonNamesIt() {
        let without = ActionCatalog.all.filter { $0.id != .attachFiles }
        #expect(ShortcutTip.action(.attachFiles, in: without) == nil)
        #expect(ShortcutTip.action(.attachFiles, in: without, title: "Attach") == ShortcutTip(title: "Attach"))
    }

    @Test func titlesDropTheMenuEllipsis() {
        #expect(ShortcutTip.displayTitle("Snooze…") == "Snooze")
        #expect(ShortcutTip.displayTitle("Insert snippet...") == "Insert snippet")
        #expect(ShortcutTip.displayTitle("Mark done") == "Mark done")
        #expect(ShortcutTip.action(.sendLater, in: ActionCatalog.all)?.title == "Send later")
    }

    @Test func fixedEditingKeysSplitIntoKeycaps() {
        #expect(ShortcutTip.keycaps(symbols: "⌘B") == ["⌘", "B"])
        #expect(ShortcutTip.keycaps(symbols: "⇧⌘X") == ["⌘", "shift", "X"])
        #expect(ShortcutTip.keycaps(symbols: "⌘\\") == ["⌘", "\\"])
        #expect(ShortcutTip.keycaps(symbols: "−") == ["−"])
    }

    @Test func theSpokenDetailNamesTheKeysAndTheHint() throws {
        let attach = ShortcutTip(title: "Attach files", keycaps: ["⌘", "shift", "U"], hint: "(or drag ’n’ drop files)")
        #expect(attach.spokenDetail == "Command Shift U. (or drag ’n’ drop files)")
        #expect(ShortcutTip(title: "Pop out").spokenDetail.isEmpty)
        #expect(ShortcutTip(title: "Send", hint: "").hint == nil)
        let selectAll = try #require(SelectAllShortcuts.tip())
        #expect(selectAll.rows.count == 2 && selectAll.hint == nil)
        #expect(selectAll.spokenDetail == "Select All: Command Shift A. Select All From Here: Command A")
    }
}
