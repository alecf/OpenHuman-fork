import AppKit
import Carbon
import MailActions
import MailFeatures
import MailModel
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
struct MenuBarItemMacTests {
    @Test func theMenuIsOpenMailNewMessageAndQuitWithNoKeyEquivalents() {
        let item = MacMenuBarItem()
        let menu = item.makeMenu()
        #expect(menu.items.map(\.title) == ["Open Mail", ActionCatalog.descriptor(.compose)?.title ?? "", "", "Quit Mail"])
        #expect(menu.items[2].isSeparatorItem)
        let entries = menu.items.filter { !$0.isSeparatorItem }
        #expect(entries.allSatisfy { $0.target === item && $0.action == #selector(MacMenuBarItem.choose(_:)) })
        #expect(entries.allSatisfy { $0.keyEquivalent.isEmpty }, "no key equivalent to clash with the app's keys")
    }

    @Test func listedConversationsSitAboveTheCommandsAndOpenTheirThread() {
        let item = MacMenuBarItem()
        let key = ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t7"))
        let long = String(repeating: "x", count: 200)
        var opened: [ThreadKey] = []
        item.setThreads([MenuBarThreadItem(key: key, title: "Sam", detail: "Invoice", isImportant: true),
                         MenuBarThreadItem(key: key, title: "New important message", detail: long, isImportant: true)]) { opened.append($0) }
        let menu = item.makeMenu()
        #expect(menu.items.map(\.title).prefix(3) == ["Unread", "Sam: Invoice", String(("New important message: " + long).prefix(59)) + "…"])
        #expect(!menu.items[0].isEnabled, "the header is a label")
        #expect(menu.items[3].isSeparatorItem && menu.items[4].title == "Open Mail")
        item.chooseThread(menu.items[1])
        #expect(opened == [key])
        item.chooseThread(NSMenuItem(title: "Stray", action: nil, keyEquivalent: ""))
        #expect(opened.count == 1, "an entry outside the list does nothing")
        item.setThreads([]) { _ in }
        #expect(item.makeMenu().items.map(\.title) == ["Open Mail", ActionCatalog.descriptor(.compose)?.title ?? "", "", "Quit Mail"])
    }

    @Test func eachEntryCallsTheHandlerWithItsCommand() {
        let item = MacMenuBarItem()
        var chosen: [MenuBarCommand] = []
        item.handler = { chosen.append($0) }
        for entry in item.makeMenu().items where !entry.isSeparatorItem { item.choose(entry) }
        #expect(chosen == [.openMail, .compose, .quit])
        let stray = NSMenuItem(title: "Other", action: nil, keyEquivalent: "")
        item.choose(stray)
        #expect(chosen.count == 3, "an entry without a command does nothing")
    }

    @Test func voiceOverReadsTheCountWithItsMeaning() {
        #expect(MacMenuBarItem.accessibilityLabel(count: "") == "OpenHuman Mail")
        #expect(MacMenuBarItem.accessibilityLabel(count: "12") == "OpenHuman Mail, 12 unread")
    }

    @Test func theIconIsATemplateImage() throws {
        let icon = try #require(MacMenuBarItem.icon())
        #expect(icon.isTemplate, "the system tints it for light, dark and highlighted menu bars")
    }
}

struct CarbonHotkeyTableTests {
    @Test func everyLetterAndDigitHasItsOwnANSIKey() {
        let keys = (65...90).map { String(UnicodeScalar($0)!) } + (0...9).map(String.init)
        let codes = keys.compactMap { CarbonGlobalHotkey.keyCode($0) }
        #expect(codes.count == 36 && Set(codes).count == 36)
        #expect(CarbonGlobalHotkey.keyCode("M") == UInt32(kVK_ANSI_M))
        #expect(CarbonGlobalHotkey.keyCode("m") == UInt32(kVK_ANSI_M))
        #expect(CarbonGlobalHotkey.keyCode("1") == UInt32(kVK_ANSI_1))
        #expect(CarbonGlobalHotkey.keyCode("é") == nil && CarbonGlobalHotkey.keyCode("#") == nil && CarbonGlobalHotkey.keyCode("") == nil)
    }

    @Test func modifiersMapToCarbonBits() {
        #expect(CarbonGlobalHotkey.carbonModifiers([.control, .option]) == UInt32(controlKey | optionKey))
        #expect(CarbonGlobalHotkey.carbonModifiers([.command, .shift]) == UInt32(cmdKey | shiftKey))
        #expect(CarbonGlobalHotkey.carbonModifiers([]) == 0)
        #expect(CarbonGlobalHotkey.carbonModifiers([.command, .option, .control, .shift])
                == UInt32(cmdKey | optionKey | controlKey | shiftKey))
    }

    @Test func theDefaultShortcutHasAKey() throws {
        let hotkey = try GlobalHotkeyRules.hotkey(for: GlobalHotkeyRules.defaultBinding).get()
        #expect(CarbonGlobalHotkey.keyCode(hotkey.key) != nil)
    }

    @Test func aShiftedDigitKeepsItsShift() throws {
        let binding = try KeyBinding(parsing: "⌃⌥⇧1")
        let hotkey = try GlobalHotkeyRules.hotkey(for: binding).get()
        #expect(hotkey.key == "1" && hotkey.modifiers == [.control, .option, .shift])
    }
}

@MainActor
struct LayoutHotkeyTests {
    @Test func aLetterIsTheKeyThatTypesItOnThisLayout() throws {
        let layout = ASCIIKeyLayout()
        for letter in ["m", "a", "z", "q"] {
            let code = try #require(CarbonGlobalHotkey.layoutKeyCode(letter, on: layout), "\(letter)")
            #expect(layout.character(keyCode: UInt16(code), shift: false)?.lowercased() == letter)
            #expect(CarbonGlobalHotkey.layoutKeyCode(letter.uppercased(), on: layout) == code, "the capital is the same key")
        }
        #expect(CarbonGlobalHotkey.layoutKeyCode("1", on: layout) == nil, "digits keep their top-row key")
        #expect(CarbonGlobalHotkey.layoutKeyCode("#", on: layout) == nil && CarbonGlobalHotkey.layoutKeyCode("", on: layout) == nil)
    }

    @Test func theLayoutAnswersAreCachedAndConsistent() {
        let layout = ASCIIKeyLayout()
        let first = layout.character(keyCode: 0, shift: false)
        #expect(first != nil, "an ASCII-capable layout always exists (TextInputSources.h: the Setup Assistant's default)")
        #expect(layout.character(keyCode: 0, shift: false) == first)
        #expect(layout.character(keyCode: 0, shift: true)?.lowercased() == first?.lowercased())
    }
}
