import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct ReplyFollowWindowTests {
    static let frameName = "dev.openhuman.tests.reply-follow"

    private func isInView(_ composer: InlineComposerView, _ w: InlineReplyWindow) -> Bool {
        w.window.contentView?.layoutSubtreeIfNeeded()
        let visible = w.reader.focusView.visibleRect
        return visible.contains(composer.convert(composer.bounds, to: w.reader.focusView).insetBy(dx: 1, dy: 1))
    }

    private func settleMainQueue(_ w: InlineReplyWindow) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
        w.window.contentView?.layoutSubtreeIfNeeded()
    }

    @discardableResult
    private func growAbove(_ w: InlineReplyWindow, by points: CGFloat, _ composer: InlineComposerView) throws -> NSLayoutConstraint {
        let document = w.reader.focusView
        w.window.contentView?.layoutSubtreeIfNeeded()
        let host = try #require(composer.hostMessage)
        let top = composer.convert(composer.bounds, to: document).minY
        let candidates = w.reader.messageViews.values
            .filter { $0 !== host && !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
            .sorted { $0.convert($0.bounds, to: document).minY < $1.convert($1.bounds, to: document).minY }
        for above in candidates {
            let grow = above.heightAnchor.constraint(greaterThanOrEqualToConstant: above.frame.height + points)
            grow.isActive = true
            w.window.contentView?.layoutSubtreeIfNeeded()
            if composer.convert(composer.bounds, to: document).minY >= top + points - 1 { return grow }
            grow.isActive = false
            w.window.contentView?.layoutSubtreeIfNeeded()
        }
        Issue.record("no message above the reply could grow")
        throw TimeoutError()
    }

    private func openReply(_ w: InlineReplyWindow) async throws -> InlineComposerView {
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await until { composer.hasKeyboardFocus }
        try await until { isInView(composer, w) }
        return composer
    }

    @Test func aJustOpenedReplyIsKeptInViewWhileTheConversationAboveGrowsAndScrollsByCodeDoNotStopThat() async throws {
        let w = try await InlineReplyWindow.make(size: NSSize(width: 1100, height: 700), frameName: Self.frameName)
        defer { w.close() }
        let composer = try await openReply(w)
        let clip = try #require(w.reader.focusView.enclosingScrollView?.contentView)

        try growAbove(w, by: 600, composer)
        try await until { isInView(composer, w) }

        clip.scroll(to: .zero)
        w.reader.focusView.enclosingScrollView?.reflectScrolledClipView(clip)
        try growAbove(w, by: 300, composer)
        try await until { isInView(composer, w) }
    }

    @Test func editingTheDraftOrScrollingEndsTheFollowing() async throws {
        let w = try await InlineReplyWindow.make(size: NSSize(width: 1100, height: 700), frameName: Self.frameName)
        defer { w.close() }
        let composer = try await openReply(w)
        let clip = try #require(w.reader.focusView.enclosingScrollView?.contentView)

        w.reader.userScrolled()
        try growAbove(w, by: 600, composer)
        await settleMainQueue(w)
        #expect(!isInView(composer, w), "no longer pulled back once the user scrolled")

        #expect(w.window.makeFirstResponder(w.reader.focusView))
        #expect(w.router.perform(.reply))
        try await until { composer.hasKeyboardFocus && isInView(composer, w) }
        let editor = try #require(w.editors.first)
        editor.insertText("Thanks", replacementRange: editor.selectedRange())
        await settleMainQueue(w)
        let before = clip.bounds.origin
        try growAbove(w, by: 600, composer)
        await settleMainQueue(w)
        #expect(clip.bounds.origin == before, "an edited draft is not pulled back: the caret's own reveal takes over")
    }
}
