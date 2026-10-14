import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func calendarDayViewAndCreateEvent(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment(calendar: true)
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let model = try #require(environment.calendarSidebar)
        #expect(environment.actions.perform(.calendarToggleSidebar, source: .menu, host: environment.router))
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        try await until { model.thread == thread && model.state == .loaded }
        try await sweepShoot(w.window, screen: "calendar-day-view", theme: theme)

        let day = try #require(model.dayViewDay)
        let busy = day.events.first { !$0.isAllDay }
        let start = busy?.start ?? day.start.addingTimeInterval(10 * 3_600)
        await model.beginDraft(for: thread, at: CalendarDateMention(date: start, hasTime: true))
        try await until { model.draft != nil && model.state == .loaded }
        try await sweepShoot(w.window, screen: "calendar-create-event-conflict", theme: theme)
        model.cancelDraft()
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func composerWithCalendarSidebar(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment(calendar: true)
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let model = try #require(environment.calendarSidebar)
        #expect(environment.actions.perform(.calendarToggleSidebar, source: .menu, host: environment.router))
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        _ = try await w.inlineComposer()
        let editor = try #require(w.editors.first)
        editor.window?.makeFirstResponder(editor)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let words = tomorrow.formatted(.dateTime.weekday(.wide).month(.wide).day())
        editor.insertText("Could we meet on \(words) at 3pm instead?", replacementRange: editor.selectedRange())
        try await until(timeout: .seconds(60)) { !editor.dateSpans.isEmpty }
        await model.follow(typed: editor.string)
        try await until { model.state == .loaded }
        try await sweepShoot(w.window, screen: "composer-with-calendar-sidebar", theme: theme)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func composerDateTooltip(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let window = sweepStandaloneWindow(DateCaretTipView().fixedSize().padding(24), store: store,
                                           size: NSSize(width: 260, height: 110))
        defer { window.orderOut(nil) }
        try await sweepShoot(window, screen: "composer-date-tooltip", theme: theme)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func quickReplyChipStates(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let stage = try await StripStage.make(theme: store.resolved)
        defer { stage.close() }
        stage.window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let strip = try #require(stage.env.compose.instantReply(for: stage.session))
        #expect(strip.preview(0))
        try await sweepShoot(stage.window, screen: "composer-quick-replies-previewed", theme: theme)
        strip.use(0, via: .click)
        try await until { strip.insertedUntouched }
        try await sweepShoot(stage.window, screen: "composer-auto-draft", theme: theme)
    }
}
