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
@Suite(.serialized)
struct OverlayWindowTests {
    @Test func theWindowInstallsThePresenterAndOverlaysTakeTheKeys() async throws {
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 60, now: Date(timeIntervalSince1970: 1_791_000_000)),
                                              options: .init(remoteAck: .immediate))
        #expect(environment.actions.presenter == nil)
        let themes = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light)))
        var attached: MainContentViewController?
        let hosting = NSHostingView(rootView: MainWindowRoot(environment: environment, themes: themes) { attached = $0 })
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        #expect(window.setFrameAutosaveName("dev.openhuman.tests.overlay-window"))
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.setFrameAutosaveName("")
        }
        try await until { attached != nil && environment.router.list?.state == .loaded }
        let content = try #require(attached)
        try await until { environment.actions.presenter != nil }

        #expect(content.keyRouter.activeScopes().contains(.list))
        #expect(environment.router.perform(.commandPalette))
        #expect(environment.overlays.isShowing)
        #expect(content.keyRouter.activeScopes() == [.global], "j, k, e and the other list keys stay with the overlay")
        #expect(environment.router.perform(.commandPalette))
        #expect(!environment.overlays.isShowing)
        #expect(content.keyRouter.activeScopes().contains(.list))

        #expect(environment.router.perform(.search))
        #expect(environment.router.active?.searchOpen == true)
        environment.overlays.search.escape()
        #expect(environment.router.active?.searchOpen == false)
    }
}
