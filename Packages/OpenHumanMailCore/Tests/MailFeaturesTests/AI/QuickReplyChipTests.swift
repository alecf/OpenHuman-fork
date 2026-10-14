import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct QuickReplyChipTests {
    @Test func hoverPreviewsGreyAndAnInsertedReplyIsAnAutoDraftUntilTyped() async throws {
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        let (session, editor, model) = try await f.readyStrip()
        model.hover(1)
        #expect(model.hovered == 1 && model.ghostText == InstantReplyTests.second)
        #expect(editor.text.isEmpty && !session.hasUserEdits, "the preview is not text")
        model.hover(nil)
        #expect(model.ghostText == nil)
        #expect(model.preview(2) && model.selection == 2 && model.ghostText == InstantReplyTests.third)
        model.hover(0)
        #expect(model.ghostText == InstantReplyTests.first, "the pointer wins while it is there")
        model.use(2, via: .click)
        #expect(editor.text == InstantReplyTests.third && model.insertedUntouched)
        #expect(model.hovered == nil)
        _ = editor.replaceText(in: 0..<0, with: "Hi. ")
        #expect(!model.insertedUntouched, "typed into: a plain Draft again")
    }

    @Test func aChipClickedUnderTheMessageIsPreviewedInTheReply() async throws {
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        let (session, editor, model) = try await f.readyStrip()
        session.pendingQuickReplyPreview = 1
        model.applyPendingPreview()
        #expect(model.selection == 1 && model.ghostText == InstantReplyTests.second)
        #expect(session.pendingQuickReplyPreview == nil && editor.text.isEmpty)
        #expect(f.center.showsQuickReplyChips)
    }
}
