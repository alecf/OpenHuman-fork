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
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct InlineReplySnapshotTests {
    func shoot(_ w: InlineReplyWindow, _ name: String) async throws {
        try await until(timeout: .seconds(60)) {
            SnapshotRenderTests.webViews(in: w.window.contentView!).allSatisfy { $0.measuredHeight != nil }
        }
        try await Task.sleep(for: .milliseconds(400))
        try SnapshotRenderTests().snapshot(w.window, name: name)
    }

    @Test(arguments: [(640.0, AppearanceMode.light), (1100.0, .light), (640.0, .dark), (1100.0, .dark)])
    func inlineReply(width: Double, mode: AppearanceMode) async throws {
        for safeMode in [SafeModeInfo.normal, .readOnly] {
            let w = try await InlineReplyWindow.make(safeMode: safeMode, size: NSSize(width: width, height: 820), mode: mode)
            let (thread, _) = try await w.conversationWithAMiddleSender()
            _ = try await w.open(thread)
            #expect(w.router.perform(.reply))
            let composer = try await w.inlineComposer()
            let tag = "\(Int(width))-\(mode.rawValue)-\(safeMode == .readOnly ? "readonly" : "normal")"
            try await shoot(w, "reply-\(tag)-empty")
            let editor = try #require(w.editors.first)
            editor.insertText("Thanks, Thursday works for me.\nI'll bring the numbers.", replacementRange: editor.selectedRange())
            composer.session.isQuoteExpanded = true
            try await shoot(w, "reply-\(tag)-typed-quote")
            w.close()
        }
    }

    @Test func replyToAMiddleMessageAndTheFullComposer() async throws {
        let w = try await InlineReplyWindow.make(size: NSSize(width: 1100, height: 900))
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        let middle = messages[messages.count - 2]
        model.toggle(middle.id)
        try await until { w.reader.messageViews[middle.id]?.header != nil }
        w.reader.performMessageAction(.reply, on: middle.id)
        let composer = try await w.inlineComposer()
        try await shoot(w, "reply-middle-1100-light")
        composer.session.openSnippetPicker()
        try await shoot(w, "reply-middle-1100-light-snippets")
        composer.session.closeSnippetPicker()
        w.environment.compose.close(try #require(w.environment.compose.windowSession))
        #expect(w.router.perform(.compose))
        try await until { w.environment.compose.windowSession?.placement == .modal }
        try await shoot(w, "compose-new-1100-light")
        w.close()
    }
}
