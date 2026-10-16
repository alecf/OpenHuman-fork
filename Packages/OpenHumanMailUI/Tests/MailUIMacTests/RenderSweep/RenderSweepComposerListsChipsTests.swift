import AppKit
import MailActions
import MailFeatures
import MailModel
import MailUI
import OpenHumanCore
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func composerListsAndChips(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let compose = w.environment.compose
        #expect(w.router.perform(.compose))
        try await until { compose.windowSession?.placement == .modal }
        let session = try #require(compose.windowSession)
        await session.settle()
        let robin = EmailAddress(name: "Robin Park", email: "robin@example.test")
        let sam = EmailAddress(email: "sam@example.test")
        session.to.setTokens([robin, sam])
        session.subject = "Plan for the offsite"
        let editor = try #require(w.editors.first)
        for key in "Agenda:\n1. Arrive by nine\nWalk-through\n\n- Bring a laptop\nNotes\n\nThanks" {
            if key == "\n" {
                editor.insertNewline(nil)
            } else {
                editor.insertText(String(key), replacementRange: editor.selectedRange())
            }
        }
        try await sweepShoot(w.window, screen: "composer-auto-lists", theme: theme)

        session.beginRecipientDrag(sam, from: .to)
        try await sweepShoot(w.window, screen: "composer-chip-drop-targets", theme: theme)
        _ = session.dropRecipient(on: .cc, undoManager: nil)
        try await sweepShoot(w.window, screen: "composer-chip-moved-to-cc", theme: theme)
    }
}
