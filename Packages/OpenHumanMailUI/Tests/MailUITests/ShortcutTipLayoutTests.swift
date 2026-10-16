#if os(macOS)
import AppKit
#endif
import CoreGraphics
import MailActions
import MailTheme
import SwiftUI
import Testing
@testable import MailUI

struct ShortcutTipLayoutTests {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let size = CGSize(width: 160, height: 30)

    func place(_ anchor: CGRect, in bounds: CGRect? = nil, alignment: ShortcutTipAlignment = .center,
               rightToLeft: Bool = false) -> CGRect {
        ShortcutTipPlacement.frame(anchor: anchor, size: size, bounds: bounds ?? self.bounds, gap: 4, margin: 8,
                                   alignment: alignment, rightToLeft: rightToLeft)
    }

    @Test func theTipSitsCentredBelowItsButton() {
        let button = CGRect(x: 300, y: 40, width: 28, height: 28)
        let frame = place(button)
        #expect(frame.minY == button.maxY + 4)
        #expect(frame.midX == button.midX)
        #expect(frame.size == size)
        #expect(!frame.intersects(button))
    }

    @Test func leadingAlignmentFollowsTheReadingDirection() {
        let button = CGRect(x: 300, y: 40, width: 28, height: 28)
        #expect(place(button, alignment: .leading).minX == button.minX)
        #expect(place(button, alignment: .leading, rightToLeft: true).maxX == button.maxX)
    }

    @Test func theTipStaysInsideTheSides() {
        #expect(place(CGRect(x: 2, y: 40, width: 28, height: 28)).minX == 8)
        #expect(place(CGRect(x: 772, y: 40, width: 28, height: 28)).maxX == 792)
        #expect(place(CGRect(x: 790, y: 40, width: 10, height: 28), alignment: .leading).maxX == 792)
        #expect(place(CGRect(x: 0, y: 40, width: 10, height: 28), alignment: .leading, rightToLeft: true).minX == 8)
    }

    @Test func nearTheBottomTheTipGoesAboveAndNeverCoversItsButton() {
        let low = CGRect(x: 300, y: 560, width: 28, height: 28)
        let frame = place(low)
        #expect(frame.maxY == low.minY - 4)
        #expect(!frame.intersects(low))
    }

    @Test func withRoomNeitherWayTheTipStaysBelow() {
        let button = CGRect(x: 300, y: 16, width: 28, height: 28)
        let frame = place(button, in: CGRect(x: 0, y: 0, width: 800, height: 60))
        #expect(frame.minY == button.maxY + 4)
    }

    @Test func theDelayIsTheThemeTooltipToken() {
        let timing = ShortcutTipTiming(theme: .light)
        #expect(timing.delay == .milliseconds(Int(ThemeTokens.light.motionTooltipDelay.rounded())))
        #expect(timing.warm == .milliseconds(Int(ThemeTokens.light.motionTooltipWarm.rounded())))
        #expect(timing.wait(sinceLastHidden: nil) == timing.delay, "cold")
        #expect(timing.wait(sinceLastHidden: .zero) == .zero, "another tip just hid")
        #expect(timing.wait(sinceLastHidden: timing.warm) == timing.delay, "cold again")
    }

    @Test func buttonsReadTheUsersBindingsFromTheEnvironment() {
        let values = EnvironmentValues()
        #expect(values.actionDescriptors == ActionCatalog.all)
        #expect(values.pinnedShortcutTip == nil)
    }

    #if os(macOS)
    @MainActor
    @Test func theHintIsASecondLineUnderTheKeys() {
        let keys = ShortcutTip(title: "Attach files", keycaps: ["⌘", "shift", "U"])
        let hinted = ShortcutTip(title: "Attach files", keycaps: ["⌘", "shift", "U"], hint: "(or drag ’n’ drop files)")
        let plain = NSHostingView(rootView: ShortcutTipView(tip: keys).environment(\.theme, .light))
        let withHint = NSHostingView(rootView: ShortcutTipView(tip: hinted).environment(\.theme, .light))
        #expect(withHint.fittingSize.height > plain.fittingSize.height)
        #expect(withHint.fittingSize.width >= plain.fittingSize.width)
    }
    #endif
}
