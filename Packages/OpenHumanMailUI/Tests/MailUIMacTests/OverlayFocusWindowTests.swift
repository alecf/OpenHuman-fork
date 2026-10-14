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
@Suite(.serialized) struct OverlayFocusWindowTests {
    static let frameName = "dev.openhuman.tests.overlay-focus"

    private func commandK(_ w: InlineReplyWindow) -> Bool {
        w.content.keyRouter.route(Keys.event("k", code: 40, modifiers: .command, window: w.window)) == nil
    }

    private func palette(_ w: InlineReplyWindow) -> PaletteController? {
        if case .palette(let palette) = w.environment.overlays.overlay { palette } else { nil }
    }

    private func focusedField(_ w: InlineReplyWindow) -> NSTextField? {
        OverlayFocusKeeper.control(of: w.window.firstResponder) as? NSTextField
    }

    private func typeInOverlayInput(_ w: InlineReplyWindow, _ text: String, besides: NSView? = nil) async throws {
        try await wait("the overlay's input has the keys", w) {
            guard let field = focusedField(w) else { return false }
            return besides.map { !field.isDescendant(of: $0) && field !== $0 } ?? true
        }
        let editor = try #require(w.window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    @Test func commandKFromTheReplyComposerFocusesThePaletteAndClosingGivesTheCaretBack() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await wait("the reply has the keys", w) { composer.hasKeyboardFocus }
        let body = try #require(w.editors.first)
        body.insertText("Thanks Dana", replacementRange: body.selectedRange())
        body.setSelectedRange(NSRange(location: 6, length: 0))

        #expect(commandK(w))
        try await typeInOverlayInput(w, "arc", besides: composer)
        let palette = try #require(palette(w))
        #expect(palette.query == "arc", "what is typed is the palette's query")
        #expect(body.string == "Thanks Dana", "and nothing reaches the draft")
        #expect(palette.context?.scope == .composer, "the palette acts on the composer")

        palette.close()
        try await wait("the draft has the keys back", w) { w.window.firstResponder === body }
        #expect(body.selectedRange() == NSRange(location: 6, length: 0), "the caret is where it was")
        body.insertText(",", replacementRange: body.selectedRange())
        #expect(body.string == "Thanks, Dana")
    }

    @Test func commandKFromTheModalComposerAndCommandKAgainGivesTheBodyBack() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        w.environment.compose.present(.compose(.mailto(EmailAddress(name: "Dana Reyes", email: "dana@example.org"),
                                                      subject: "Agenda")))
        try await wait("the new message is open", w) { w.environment.compose.windowSession?.placement == .modal && !w.editors.isEmpty }
        let body = try #require(w.editors.first)
        #expect(w.window.makeFirstResponder(body))
        try await wait("the draft has the keys", w) { w.window.firstResponder === body }
        body.insertText("Agenda", replacementRange: body.selectedRange())

        #expect(commandK(w))
        try await typeInOverlayInput(w, "bold", besides: body)
        #expect(palette(w)?.query == "bold")
        #expect(body.string == "Agenda")
        #expect(commandK(w))
        try await wait("the draft has the keys back", w) { w.window.firstResponder === body }
        #expect(body.selectedRange() == NSRange(location: 6, length: 0))
    }

    @Test func aLateRequestFromTheComposerDoesNotTakeThePalettesKeys() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await wait("the reply has the keys", w) { composer.hasKeyboardFocus }
        let body = try #require(w.editors.first)

        #expect(commandK(w))
        try await wait("a field outside the reply has the keys", w) { focusedField(w).map { !$0.isDescendant(of: composer) } ?? false }
        #expect(w.window.makeFirstResponder(body), "the composer takes the keys back")
        try await typeInOverlayInput(w, "snooze", besides: composer)
        #expect(palette(w)?.query == "snooze")
        #expect(body.string.isEmpty)
    }

    @Test func commandKAgainRightAfterClosingStillFocusesTheInput() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await wait("the reply has the keys", w) { composer.hasKeyboardFocus }
        let body = try #require(w.editors.first)
        for round in 0..<3 {
            #expect(commandK(w))
            try await typeInOverlayInput(w, "s\(round)", besides: composer)
            #expect(palette(w)?.query == "s\(round)")
            palette(w)?.close()
        }
        try await wait("the draft has the keys back", w) { w.window.firstResponder === body }
        #expect(body.string.isEmpty, "nothing reached the draft")
    }

    @Test func sendLaterFromTheComposerFocusesThePickerAndGivesTheCaretBack() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await wait("the reply has the keys", w) { composer.hasKeyboardFocus }
        let body = try #require(w.editors.first)
        body.insertText("See you then", replacementRange: body.selectedRange())

        #expect(w.environment.compose.perform(.sendLater, in: composer.session, source: .keyboard))
        guard case .time(let picker) = w.environment.overlays.overlay else {
            Issue.record("the send-later picker is up")
            return
        }
        try await typeInOverlayInput(w, "tomorrow 9am", besides: composer)
        #expect(picker.text == "tomorrow 9am")
        #expect(body.string == "See you then")
        w.environment.overlays.dismiss()
        try await wait("the draft has the keys back", w) { w.window.firstResponder === body }
        #expect(body.selectedRange() == NSRange(location: 12, length: 0))
    }

    @Test func commandKFromTheListAndAConversation() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        try await wait("the list has the keys", w) { w.window.firstResponder === w.content.tableView }
        #expect(commandK(w))
        try await typeInOverlayInput(w, "inbox")
        #expect(palette(w)?.query == "inbox")
        palette(w)?.close()
        try await wait("the list has the keys back", w) { w.window.firstResponder === w.content.tableView }

        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        try await wait("the conversation has the keys", w) { w.window.firstResponder === w.reader.focusView }
        #expect(commandK(w))
        try await typeInOverlayInput(w, "star")
        #expect(palette(w)?.query == "star")
        palette(w)?.close()
        try await wait("the conversation has the keys back", w) { w.window.firstResponder === w.reader.focusView }
    }

    private func wait(_ what: String, _ w: InlineReplyWindow, _ condition: @MainActor () -> Bool) async throws {
        do {
            try await until(condition)
        } catch {
            Issue.record("timed out: \(what); the first responder is \(String(describing: w.window.firstResponder))")
            throw error
        }
    }

    @Test func commandKFromTheSearchFieldGivesTheFieldBackWithItsText() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, exclusive: true)
        defer { w.close() }
        let before = OverlayFocusKeeper.editableFields(in: w.window)
        #expect(w.router.perform(.search))
        try await wait("the search field is shown", w) {
            OverlayFocusKeeper.editableFields(in: w.window).contains { field in !before.contains { $0 === field } }
        }
        let searchField = try #require(OverlayFocusKeeper.editableFields(in: w.window).first { field in
            !before.contains { $0 === field }
        })
        if focusedField(w) !== searchField { #expect(w.window.makeFirstResponder(searchField)) }
        try await wait("the search field has the keys", w) { focusedField(w) === searchField }
        let editor = try #require(w.window.firstResponder as? NSTextView)
        editor.insertText("budget", replacementRange: editor.selectedRange())
        #expect(w.environment.overlays.search.text == "budget")

        #expect(commandK(w))
        try await typeInOverlayInput(w, "go", besides: searchField)
        #expect(palette(w)?.query == "go")
        #expect(w.environment.overlays.search.text == "budget")
        palette(w)?.close()
        try await wait("the search field has the keys back", w) { focusedField(w) === searchField }
        let back = try #require(w.window.firstResponder as? NSTextView)
        #expect(back.selectedRange() == NSRange(location: 6, length: 0), "the caret after the typed text, not all selected")
    }
}
