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
    func shortcutTipUnderTheComposeButton(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment()
        let w = try await SweepWindow.make(environment, theme: theme, pinnedTip: .compose)
        defer { w.close() }
        try await sweepShoot(w.window, screen: "shortcut-tip-toolbar-compose", theme: theme)
    }

    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light,dark"))
    func shortcutTipWithAHintUnderAttach(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment()
        let w = try await SweepWindow.make(environment, theme: theme, pinnedTip: .attachFiles)
        defer { w.close() }
        #expect(w.router.perform(.compose))
        try await until { w.environment.compose.windowSession?.placement == .modal }
        try await sweepShoot(w.window, screen: "shortcut-tip-composer-attach", theme: theme)
    }

    @Test(arguments: SweepTheme.selected(SweepTheme.allBuiltIns, slugs: "light,dark"))
    func shortcutTipUnderTheRightPaneClose(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment()
        let w = try await SweepWindow.make(environment, theme: theme, pinnedTip: .toggleContextSidebar)
        defer { w.close() }
        #expect(environment.actions.perform(.toggleContextSidebar, source: .menu, host: w.router))
        try await sweepShoot(w.window, screen: "shortcut-tip-right-pane-close", theme: theme)
    }
}
