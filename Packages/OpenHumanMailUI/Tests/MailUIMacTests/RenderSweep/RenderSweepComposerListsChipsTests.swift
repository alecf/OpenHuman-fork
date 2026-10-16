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
        let session = try #require(compose.windowSession)
        #expect(session.placement == .modal)
        await session.settle()
        let robin = EmailAddress(name: "Robin Park", email: "robin@example.test")
        let sam = EmailAddress(email: "sam@example.test")
        session.to.setTokens([robin, sam])
        session.subject = "Plan for the offsite"
        w.window.contentView?.layoutSubtreeIfNeeded()
        let editor = try #require(w.editors.first)
        #expect(w.window.makeFirstResponder(editor))
        for key in "Agenda:\n1. Arrive by nine\nWalk-through\n\n- Bring a laptop\nNotes\n\nThanks" {
            let event = try #require(keyDownEvent(key, in: w.window))
            if w.content.keyRouter.route(event) != nil { w.window.sendEvent(event) }
            await runLoopGoesIdle()
        }
        #expect(shownParagraphs(editor).map(\.string) == ["Agenda:\n", "\t1.\tArrive by nine\n", "\t2.\tWalk-through\n",
                                                          "\t•\tBring a laptop\n", "\t•\tNotes\n", "Thanks"])
        try await sweepShoot(w.window, screen: "composer-auto-lists", theme: theme)

        session.beginRecipientDrag(sam, from: .to)
        try await sweepShoot(w.window, screen: "composer-chip-drop-targets", theme: theme)
        _ = session.dropRecipient(on: .cc, undoManager: nil)
        try await sweepShoot(w.window, screen: "composer-chip-moved-to-cc", theme: theme)
    }
}
