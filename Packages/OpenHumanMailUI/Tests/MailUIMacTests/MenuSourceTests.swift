import AppKit
import MailActions
import Testing
@testable import MailUIMac

@Suite struct MenuSourceTests {
    @Test func aKeyEquivalentIsTheKeyboardAndAnythingElseTheMenu() {
        #expect(MailCommands.source(for: .keyDown) == .keyboard)
        #expect(MailCommands.source(for: .leftMouseUp) == .menu)
        #expect(MailCommands.source(for: .leftMouseDown) == .menu)
        #expect(MailCommands.source(for: .appKitDefined) == .menu)
        #expect(MailCommands.source(for: nil) == .menu, "VoiceOver or no current event")
    }
}
