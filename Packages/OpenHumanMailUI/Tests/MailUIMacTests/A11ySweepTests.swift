import AppKit
import MailTheme
import Testing
@testable import MailUIMac

@MainActor
struct A11ySweepTests {
    @Test func aToggleIconButtonReportsOnAndOff() {
        let toggle = ReaderButton.icon("envelope", activeSymbol: "envelope.fill", help: "Mark read", theme: .light) {}
        #expect(toggle.accessibilityValue() as? String == "Off")
        toggle.isActive = true
        #expect(toggle.accessibilityValue() as? String == "On")
        toggle.isActive = false
        #expect(toggle.accessibilityValue() as? String == "Off")
    }

    @Test func aPlainIconButtonHasNoToggleValue() {
        let button = ReaderButton.icon("arrowshape.turn.up.left", help: "Reply", theme: .light) {}
        #expect(button.accessibilityValue() == nil)
        #expect(button.accessibilityLabel() == "Reply")
    }

    @Test func theOlderMessagesPillPressesThroughAccessibility() {
        let pill = OlderMessagesPillView(count: 3, theme: .light)
        var pressed = 0
        pill.onClick = { pressed += 1 }
        #expect(pill.accessibilityRole() == .button)
        #expect(pill.accessibilityLabel() == "3 older messages")
        #expect(pill.accessibilityPerformPress())
        #expect(pressed == 1)
    }

    @Test func theNewMessagesPillIsAButtonWithALabelAndPresses() {
        let pill = NewMessagesPillView(theme: .light)
        var pressed = 0
        pill.onClick = { pressed += 1 }
        pill.update(count: 2, key: "⇧N")
        #expect(pill.accessibilityRole() == .button)
        #expect(pill.accessibilityLabel()?.isEmpty == false)
        #expect(pill.accessibilityPerformPress())
        #expect(pressed == 1)
    }
}
