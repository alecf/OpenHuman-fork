import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import Testing
@testable import MailUI
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light,dark"))
    func selectMode(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let list = try #require(w.router.list)
        #expect(environment.actions.perform(.toggleContextSidebar, source: .menu, host: w.router))
        try await w.cursorAndHover(steps: 2, offset: 2)
        #expect(list.headerCheck == .hidden)
        try await sweepShoot(w.window, screen: "select-hover-and-cursor", theme: theme)

        #expect(await environment.actions.run(.toggleCheck, source: .keyboard, host: w.router))
        #expect(list.headerCheck == .some)
        try await sweepShoot(w.window, screen: "select-one-checked-shortcuts", theme: theme)

        list.checkAll()
        #expect(list.headerCheck == .all)
        try await sweepShoot(w.window, screen: "select-all-checked", theme: theme)

        list.clearChecks()
        list.setCursor(list.rows[4].id)
        list.checkFromHere()
        #expect(list.offersCheckBefore)
        try await sweepShoot(w.window, screen: "select-cmd-a-middle-toast", theme: theme)

        list.clearChecks()
        let tip = sweepStandaloneWindow(SelectAllTip(rows: SelectAllShortcuts.tipRows()), store: theme.makeStore(),
                                        size: NSSize(width: 360, height: 90))
        defer { tip.close() }
        try await sweepShoot(tip, screen: "select-header-tip", theme: theme)
    }

    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light,dark"))
    func recentOpensWithContactPane(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment()
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let list = try #require(w.router.list)
        for key in list.rows.prefix(4).map(\.id) { _ = try await w.open(key) }
        w.router.closeReader()
        #expect(w.router.recentOpens.entries.count == 4)
        #expect(environment.actions.perform(.toggleContextSidebar, source: .menu, host: w.router))
        try await sweepShoot(w.window, screen: "recent-opens-contact-pane", theme: theme)
    }
}
