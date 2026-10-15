import AppKit
import Foundation
import MailFeatures
import MailModel
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func toolbarAccountCounts(_ theme: SweepTheme) async throws {
        let environment = SweepWindow.environment()
        let settings = try #require(environment.settings)
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        w.router.isLabelSidebarVisible = true
        await awaitObserved("two accounts with their counts") {
            w.router.showsAccountSwitcher && w.router.accounts.allSatisfy { $0.counts != nil }
        }
        for mode in AccountCountMode.allCases {
            try await settings.set(AppSettings.accountCounts, mode)
            await awaitObserved("the window follows \(mode.rawValue)") { w.router.accountCountMode == mode }
            try await shootAccountCountToolbar(w.window, screen: "toolbar-account-counts-\(mode.rawValue)", theme: theme)
        }
        try await settings.set(AppSettings.accountCounts, .important)
        w.router.go(to: .system(.allMail))
        await awaitObserved("All mail is shown") {
            w.router.list?.location == .system(.allMail) && w.router.list?.state == .loaded
        }
        try await shootAccountCountToolbar(w.window, screen: "toolbar-all-mail-title", theme: theme)
    }

    private func shootAccountCountToolbar(_ window: NSWindow, screen: String, theme: SweepTheme) async throws {
        try await sweepShoot(window, screen: screen, theme: theme)
        let directory = try SweepOutput.directory()
        let source = directory.appendingPathComponent("\(screen)--\(theme.slug).png")
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: source)))
        let scale = CGFloat(rep.pixelsWide) / SweepWindow.size.width
        let strip = TitleBarMetrics.stripHeight(of: window)
        let crop = CGRect(x: 0, y: 0, width: 760 * scale, height: (strip + 120) * scale)
        let cropped = try #require(rep.cgImage?.cropping(to: crop))
        let png = try #require(NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]))
        let file = "\(screen)-crop--\(theme.slug).png"
        try png.write(to: directory.appendingPathComponent(file))
        try SweepIndex.record(SweepIndexEntry(screen: "\(screen)-crop", theme: theme.name, file: file), in: directory)
    }
}
