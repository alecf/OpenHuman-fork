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
@Suite(.serialized) struct SearchDropdownWindowTests {
    static let frameName = "dev.openhuman.tests.search-dropdown"
    static let fieldHeight: CGFloat = 32, gap: CGFloat = 4, rowHeight: CGFloat = 32

    func key(_ chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in w: InlineReplyWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 100,
                         windowNumber: w.window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private func draw(_ w: InlineReplyWindow) {
        w.window.contentView?.layoutSubtreeIfNeeded()
        w.window.displayIfNeeded()
    }

    private func wait(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        do {
            try await until(condition)
        } catch {
            Issue.record("timed out waiting for \(what)")
            throw error
        }
    }

    private func search(_ text: String, in w: InlineReplyWindow) async throws -> NSTextField {
        let model = w.environment.overlays.search
        #expect(w.router.perform(.search))
        try await wait("the search field") { model.isOpen && w.content.searchField(in: w.window) != nil }
        let field = try #require(w.content.searchField(in: w.window))
        try await wait("`/` to give the field the keys") { OverlayFocusKeeper.control(of: w.window.firstResponder) === field }
        let editor = try await fieldEditor(of: field, in: w)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        try await wait("the results for “\(text)”") {
            model.text == text && model.shownQuery == text.trimmingCharacters(in: .whitespaces)
                && w.router.list?.state == .loaded
                && w.router.list?.rows.isEmpty == false
        }
        return field
    }

    private func fieldEditor(of field: NSTextField, in w: InlineReplyWindow) async throws -> NSTextView {
        try await wait("the field's editor to have the keys") {
            if let editor = w.window.firstResponder as? NSTextView, editor.delegate === field { return true }
            w.window.makeFirstResponder(field)
            return false
        }
        return try #require(w.window.firstResponder as? NSTextView)
    }

    private func giveTheResultsTheKeys(_ w: InlineReplyWindow) async throws {
        #expect(w.environment.overlays.search.focusResults())
        try await wait("the results to take the keys") {
            if w.window.firstResponder === w.content.tableView { return true }
            _ = w.environment.overlays.search.focusResults()
            return false
        }
    }

    private func hit(_ point: NSPoint, in w: InlineReplyWindow) -> NSView? {
        let root = w.window.contentView!
        guard let frame = root.superview else { return root.hitTest(point) }
        return frame.hitTest(frame.convert(point, from: nil))
    }

    @Test(arguments: [AppearanceMode.light, .dark])
    func theDropDownIsDrawnOverTheResultsAndTakesTheirClicks(_ mode: AppearanceMode) async throws {
        let w = try await InlineReplyWindow.make(mode: mode, frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let field = try await search("s", in: w)
        let model = w.environment.overlays.search
        let editor = try await fieldEditor(of: field, in: w)
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        try await wait("the emptied field and its operator rows") { model.text.isEmpty && model.suggestions.count >= 6 }
        #expect(model.shownQuery == "s", "the results stay shown under the drop-down")
        draw(w)

        let list = w.content.view
        let listFrame = list.convert(list.bounds, to: nil)
        let fieldFrame = field.convert(field.bounds, to: nil)
        let top = fieldFrame.midY - Self.fieldHeight / 2 - Self.gap
        let inRow = NSPoint(x: fieldFrame.midX, y: top - Self.gap - Self.rowHeight * 5.5)
        #expect(listFrame.contains(inRow), "the drop-down reaches over the list")
        let table = w.content.tableView
        #expect(table.row(at: table.convert(inRow, from: nil)) >= 0, "a result row lies under the drop-down there")
        let over = try #require(hit(inRow, in: w))
        #expect(!over.isDescendant(of: list), "the drop-down, not the list under it, takes the click (got \(over))")
        let nearTop = NSPoint(x: fieldFrame.minX + 4, y: top - 2)
        #expect(!(hit(nearTop, in: w)?.isDescendant(of: list) ?? false))
        let below = NSPoint(x: fieldFrame.midX, y: listFrame.minY + 40)
        #expect(hit(below, in: w)?.isDescendant(of: list) == true, "the list keeps its clicks outside the drop-down")
    }

    @Test func backspaceInTheResultsEditsTheQueryAndTrashesNothing() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let field = try await search("subject:re", in: w)
        let model = w.environment.overlays.search
        try await giveTheResultsTheKeys(w)
        let selected = try #require(w.router.list?.cursor, "a result is selected")
        let rowsBefore = w.router.list?.rows.map(\.id) ?? []

        #expect(w.content.keyRouter.route(key("\u{7F}", code: 51, in: w)) == nil, "⌫ is taken from the results")
        try await wait("the query “subject:r”") { model.text == "subject:r" }
        #expect(OverlayFocusKeeper.control(of: w.window.firstResponder) === field, "the field has the keys")
        let editor = try await fieldEditor(of: field, in: w)
        #expect(editor.selectedRange() == NSRange(location: ("subject:r" as NSString).length, length: 0), "caret at the end")
        #expect(w.environment.undo?.canUndo != true, "nothing was trashed (no undo entry)")
        #expect(!w.environment.notices.toasts.contains { $0.actionTitle == "Undo" }, "no Undo toast")
        #expect(rowsBefore.contains(selected))

        try await wait("the results for “subject:r”") { model.shownQuery == "subject:r" }
        try await giveTheResultsTheKeys(w)
        #expect(w.content.keyRouter.route(key("\u{7F}", code: 51, modifiers: .option, in: w)) == nil)
        try await wait("the query “subject:”") { model.text == "subject:" }
        try await wait("the results for “subject:”") { model.shownQuery == "subject:" }
        try await giveTheResultsTheKeys(w)
        #expect(w.content.keyRouter.route(key("\u{F728}", code: 117, in: w)) == nil, "⌦ goes to the field too")
        #expect(model.text == "subject:")
        try await giveTheResultsTheKeys(w)
        #expect(w.content.keyRouter.route(key("\u{7F}", code: 51, modifiers: .command, in: w)) == nil)
        try await wait("the emptied query") { model.text.isEmpty }
        #expect(w.environment.undo?.canUndo != true, "still nothing trashed")
    }

    @Test func backspaceAfterThePillsTurnsTheLastPillBackIntoText() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        let field = try await search("subject:re ", in: w)
        let model = w.environment.overlays.search
        try await settleTitleBarStrip(of: w.window)
        try await wait("the operator to become a pill") {
            draw(w)
            return field.stringValue.isEmpty
        }
        try await giveTheResultsTheKeys(w)
        #expect(w.content.keyRouter.route(key("\u{7F}", code: 51, in: w)) == nil, "⌫ is taken from the results")
        try await wait("the pill as text again") { model.text == "subject:re" }
        try await wait("the field to show it") { field.stringValue == "subject:re" }
        #expect(w.environment.undo?.canUndo != true, "nothing was trashed")
    }

    @Test func hashStillTrashesTheSelectedResultWithUndo() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        _ = try await search("re", in: w)
        try await giveTheResultsTheKeys(w)
        let selected = try #require(w.router.list?.cursor)
        #expect(w.content.keyRouter.route(key("#", code: 20, modifiers: .shift, in: w)) == nil, "# is Trash")
        try await wait("the trashed row to leave") { w.router.list?.rows.contains { $0.id == selected } == false }
        try await wait("the undo entry") { w.environment.undo?.canUndo == true }
        #expect(w.environment.notices.toasts.contains { $0.actionTitle == "Undo" })
        #expect(w.environment.overlays.search.text == "re", "the query is untouched")
    }

    @Test func backspaceInAPlainListStillTrashesWithUndo() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true, exclusive: true)
        defer { w.close() }
        try await wait("the list with a cursor") { w.window.firstResponder === w.content.tableView && w.router.list?.cursor != nil }
        let selected = try #require(w.router.list?.cursor)
        #expect(!w.environment.overlays.search.isOpen)
        #expect(w.content.keyRouter.route(key("\u{7F}", code: 51, in: w)) == nil, "⌫ is Trash")
        try await wait("the trashed row to leave") { w.router.list?.rows.contains { $0.id == selected } == false }
        try await wait("the undo entry") { w.environment.undo?.canUndo == true }
        #expect(w.environment.notices.toasts.contains { $0.actionTitle == "Undo" })
    }
}
