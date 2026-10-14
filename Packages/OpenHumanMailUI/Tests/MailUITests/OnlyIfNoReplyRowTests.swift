#if os(macOS)
import AppKit
import MailFeatures
import MailTheme
import SwiftUI
import Testing
@testable import MailUI

@MainActor
@Suite struct OnlyIfNoReplyRowTests {
    private func inkPixels(theme: ResolvedTheme, on: Bool) throws -> Int {
        let sheet = OverlaySheet.theme(for: theme)
        let bg = sheet.tokens.component.palette.bg.color
        let view = OnlyIfNoReplyRow(isOn: .constant(on))
            .environment(\.theme, sheet)
            .environment(\.colorScheme, .dark)
            .frame(width: 420, height: 32)
            .background(bg)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 32)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let reference = try #require(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        func luma(_ c: NSColor) -> CGFloat { 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent }
        var count = 0
        for x in 48..<Int(rep.pixelsWide) {
            for y in 0..<Int(rep.pixelsHigh) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(luma(c) - luma(reference)) > 0.35 { count += 1 }
            }
        }
        return count
    }

    @Test(arguments: [ResolvedTheme.light, ResolvedTheme.dark])
    func theLabelIsDrawnWhetherTheBoxIsTickedOrNot(theme: ResolvedTheme) throws {
        #expect(try inkPixels(theme: theme, on: true) > 40, "label pixels, ticked, \(theme.appearance)")
        #expect(try inkPixels(theme: theme, on: false) > 40, "label pixels, unticked, \(theme.appearance)")
    }

    @Test(arguments: [ResolvedTheme.light, ResolvedTheme.dark])
    func theLabelColourReadsOnTheSheet(theme: ResolvedTheme) {
        let palette = OverlaySheet.theme(for: theme).tokens.component.palette
        #expect(palette.textSelected.contrastRatio(on: palette.bg) >= 4.5)
    }
}
#endif
