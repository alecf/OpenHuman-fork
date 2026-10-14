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
@Suite(.serialized) struct ComposerTypingLayoutTests {
    static let frameName = "dev.openhuman.tests.composer-typing"

    static let text = "Thanks for the notes. I read them twice and I think we should move the review to Thursday "
        + "afternoon, because the numbers are not ready and the team is out until Wednesday evening at the earliest.\n"
        + "Let me know.\n\nBest,\nSam\n\nPS: the room is booked."

    private func headerFrames(_ w: InlineReplyWindow, above body: NSView) -> [NSRect] {
        let bodyTop = body.convert(body.bounds, to: nil).maxY
        return OverlayFocusKeeper.editableFields(in: w.window).map { $0.convert($0.bounds, to: nil) }
            .filter { $0.minY >= bodyTop }
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    private func headerOffsets(_ composer: NSView, above body: NSView) -> [NSRect] {
        let bodyTop = body.convert(body.bounds, to: composer)
        func fromTop(_ rect: NSRect) -> NSRect {
            composer.isFlipped ? rect : NSRect(x: rect.minX, y: composer.bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        let bodyFromTop = fromTop(bodyTop).minY
        return subviews(of: NSTextField.self, in: composer).filter(\.isEditable)
            .map { fromTop($0.convert($0.bounds, to: composer)) }
            .filter { $0.maxY <= bodyFromTop + 0.5 }
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    // smartSearch off: its async read would move the header at a moment no test controls
    static let flags = FeatureFlags.atLaunch.with(.smartSearch, false)

    private func type(_ character: Character, into editor: ComposerTextView) {
        if character == "\n" {
            editor.insertNewline(nil)
        } else {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
    }

    @Test func theInlineReplyOnlyGrowsWhileTypingAndNothingAboveItMoves() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, featureFlags: Self.flags)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await until { composer.hasKeyboardFocus }
        let editor = try #require(w.editors.first)
        let scroll = try #require(editor.enclosingScrollView as? ComposerScrollView)
        let conversation = try #require(w.reader.focusView.enclosingScrollView?.contentView)
        await composer.session.settle()
        w.window.contentView?.layoutSubtreeIfNeeded()
        let header = headerOffsets(composer, above: scroll)
        #expect(!header.isEmpty, "the To field is above the body")
        let width = scroll.frame.width
        var lastHeight = scroll.frame.height
        var lastScroll = conversation.bounds.origin.y
        var grew = false
        for (index, character) in Self.text.enumerated() {
            type(character, into: editor)
            #expect(scroll.contentView.bounds.origin.y == 0, "no scroll inside the body at character \(index)")
            let expected = min(max(editor.contentHeight(forWidth: width), ComposerMetrics.editorMinDocked),
                               scroll.growsUpTo ?? .greatestFiniteMagnitude)
            try await until {
                w.window.contentView?.layoutSubtreeIfNeeded()
                return abs(scroll.frame.height - expected) < 0.5
            }
            #expect(scroll.contentView.bounds.origin.y == 0)
            #expect(scroll.frame.height >= lastHeight, "the body never shrinks while typing (character \(index))")
            if scroll.frame.height > lastHeight { grew = true }
            lastHeight = scroll.frame.height
            #expect(headerOffsets(composer, above: scroll) == header, "nothing above the body moves (character \(index))")
            let scrolled = conversation.isFlipped ? conversation.bounds.origin.y : -conversation.bounds.origin.y
            let previous = conversation.isFlipped ? lastScroll : -lastScroll
            #expect(scrolled >= previous - 0.5, "the conversation never scrolls back (character \(index))")
            lastScroll = conversation.bounds.origin.y
        }
        #expect(grew, "the text is taller than the body's first height")
        let manager = try #require(editor.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        #expect(abs(lastHeight - (manager.usageBoundsForTextContainer.height + 2 * ComposerTextView.verticalInset)) < 1)
    }

    @Test func theNewMessageComposerKeepsItsFramesWhileTyping() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, featureFlags: Self.flags)
        defer { w.close() }
        w.environment.compose.present(.compose(.mailto(EmailAddress(name: "Dana Reyes", email: "dana@example.org"),
                                                      subject: "Agenda")))
        try await until { w.environment.compose.windowSession?.placement == .modal && !w.editors.isEmpty }
        let session = try #require(w.environment.compose.windowSession)
        let editor = try #require(w.editors.first)
        let scroll = try #require(editor.enclosingScrollView)
        await session.settle()
        #expect(w.window.makeFirstResponder(editor))
        w.window.contentView?.layoutSubtreeIfNeeded()
        let header = headerFrames(w, above: scroll)
        let body = scroll.convert(scroll.bounds, to: nil)
        for (index, character) in Self.text.enumerated() {
            type(character, into: editor)
            w.window.contentView?.layoutSubtreeIfNeeded()
            #expect(scroll.convert(scroll.bounds, to: nil) == body, "the body keeps its frame (character \(index))")
            #expect(headerFrames(w, above: scroll) == header, "nothing above the body moves (character \(index))")
        }
    }

    @Test func aTrailingReturnCountsOneLine() {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 500, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let text = ComposerTextView.make()
        text.bridge = AttributedBridge(theme: .light)
        text.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        window.contentView?.addSubview(text)
        let line = text.bridge.lineHeightValue
        let insets = 2 * ComposerTextView.verticalInset
        text.insertText("one\ntwo", replacementRange: NSRange(location: 0, length: 0))
        #expect(text.contentHeight(forWidth: 400) == 2 * line + insets)
        text.insertNewline(nil)
        #expect(text.contentHeight(forWidth: 400) == 3 * line + insets, "↩ adds one line")
        text.insertText("t", replacementRange: text.selectedRange())
        #expect(text.contentHeight(forWidth: 400) == 3 * line + insets, "the next character adds none")
        #expect(text.contentHeight(forWidth: 300) == 3 * line + insets)
    }
}
