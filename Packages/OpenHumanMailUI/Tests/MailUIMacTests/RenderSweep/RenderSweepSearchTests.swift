import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func searchDropDownOverResults(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        #expect(w.router.perform(.search))
        try await until { OverlayFocusKeeper.control(of: w.window.firstResponder) is NSTextField }
        let editor = try #require(w.window.firstResponder as? NSTextView)
        editor.insertText("e", replacementRange: editor.selectedRange())
        let model = w.environment.overlays.search
        try await until { model.shownQuery == "e" && w.router.list?.state == .loaded && !model.suggestions.isEmpty }
        try await sweepShoot(w.window, screen: "search-dropdown-open", theme: theme)
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        try await until { model.text.isEmpty && model.suggestions.count >= 6 }
        try await sweepShoot(w.window, screen: "search-dropdown-operators", theme: theme)
        editor.insertText("from:dana subject:\"q4 budget\" -label:Receipts e", replacementRange: editor.selectedRange())
        try await until { model.text.hasSuffix(" e") }
        try await sweepShoot(w.window, screen: "search-operator-pills", theme: theme)
    }
}
