import AppKit
import MailFeatures
import MailModel
import SwiftUI
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func oneSuggestionSet(_ theme: SweepTheme) async throws {
        let stage = try await OneSuggestionStage.make(busy: true, composerStrip: true, theme: theme,
                                                      frameName: SweepWindow.frameName)
        defer { stage.close() }
        try await stage.open()
        let row = try #require(stage.center?.inlineReplies.current)
        try await until { row.items.contains { $0.kind == .quickReply } }
        try await sweepShoot(stage.w.window, screen: "reader-one-suggestion-set", theme: theme)

        #expect(stage.router.perform(.reply))
        let body = try await stage.body()
        try await sweepShoot(stage.w.window, screen: "reader-one-suggestion-reply-open", theme: theme)

        let ai = try #require(row.items.firstIndex { $0.kind == .quickReply })
        row.select(ai)
        try await until { body.string == row.items[ai].body }
        try await sweepShoot(stage.w.window, screen: "reader-one-suggestion-used", theme: theme)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func oneSuggestionSetAcceptAndMove(_ theme: SweepTheme) async throws {
        let stage = try await OneSuggestionStage.make(busy: true, theme: theme, frameName: SweepWindow.frameName)
        defer { stage.close() }
        try await stage.open()
        stage.assistant.conflictThread = stage.thread
        #expect(stage.router.perform(.reply))
        let body = try await stage.body()
        try await sweepShoot(stage.w.window, screen: "reader-one-suggestion-busy-meeting", theme: theme)
        stage.assistant.language = nil
        let moves = try #require(stage.assistant.analyses[stage.thread]?.moves)
        await stage.assistant.draft(.acceptAndMove(moves), in: stage.thread)
        try await until { !body.string.isEmpty }
        try await sweepShoot(stage.w.window, screen: "reader-one-suggestion-accept-and-move", theme: theme)
        let session = try #require(stage.reader.inlineComposer?.session)
        _ = try #require(stage.center?.togglePanel(session))
        try await until { stage.reader.inlineComposer?.revealedPanelFrame != nil }
        try await sweepShoot(stage.w.window, screen: "reader-one-suggestion-cmdj-below-text", theme: theme)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func oneSuggestionSetThanksNote(_ theme: SweepTheme) async throws {
        let stage = try await OneSuggestionStage.make(theme: theme, text: "Ofc. So glad you're part of our community!!",
                                                      frameName: SweepWindow.frameName)
        defer { stage.close() }
        try await stage.open()
        try await sweepShoot(stage.w.window, screen: "reader-one-suggestion-thanks-note", theme: theme)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func oneSuggestionSetFreeTime(_ theme: SweepTheme) async throws {
        let stage = try await OneSuggestionStage.make(busy: false, theme: theme, frameName: SweepWindow.frameName)
        defer { stage.close() }
        try await stage.open()
        let row = try #require(stage.center?.inlineReplies.current)
        try await until { row.items.contains { $0.kind == .quickReply } }
        try await sweepShoot(stage.w.window, screen: "reader-one-suggestion-free", theme: theme)
    }
}
