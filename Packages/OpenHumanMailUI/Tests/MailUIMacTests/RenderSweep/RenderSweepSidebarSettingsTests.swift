import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func sidebarSettingsWithFoldersHidden(_ theme: SweepTheme) async throws {
        let environment = SweepOverlayFixture.environment()
        let settings = try #require(environment.settings, "the fake environment has a settings store")
        try await settings.set(AppSettings.sidebarHidden, ["allMail", "spam"])
        try await settings.set(AppSettings.allInboxesShown, false)
        let page = sweepStandaloneWindow(SidebarSettingsPage(environment: environment), store: theme.makeStore(),
                                         size: NSSize(width: 760, height: 900))
        defer { page.orderOut(nil) }
        try await sweepShoot(page, screen: "settings-sidebar-hidden", theme: theme, settle: .milliseconds(600))
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func sidebarWithAllMailHiddenAndAllInboxesOff(_ theme: SweepTheme) async throws {
        let environment = SweepOverlayFixture.environment()
        let settings = try #require(environment.settings, "the fake environment has a settings store")
        try await settings.set(AppSettings.sidebarHidden, ["allMail"])
        try await settings.set(AppSettings.allInboxesShown, false)
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        w.router.isLabelSidebarVisible = true
        try await sweepShoot(w.window, screen: "sidebar-all-mail-hidden", theme: theme, settle: .milliseconds(600))
    }
}
