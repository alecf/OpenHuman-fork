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
struct ShellSnapshotTests {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] ?? "/tmp")

    func render(_ environment: AppEnvironment, mode: AppearanceMode, name: String,
                prepare: @MainActor (AppRouter, MainContentViewController) async throws -> Void) async throws {
        let themes = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: mode)))
        var attached: MainContentViewController?
        let hosting = NSHostingView(rootView: MainWindowRoot(environment: environment, themes: themes) { attached = $0 })
        let frame = NSRect(x: -5000, y: -5000, width: 1360, height: 860)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        #expect(window.setFrameAutosaveName("dev.openhuman.tests.shell-snapshot"))
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        try await until { attached != nil && environment.router.list?.state == .loaded }
        let content = try #require(attached)
        content.keyRouter.isMailWindow = { $0 === window }
        try await prepare(environment.router, content)
        try await Task.sleep(for: .milliseconds(300))
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
        window.setFrameAutosaveName("")
    }

    @Test func lightWithSidebarAndUndoToast() async throws {
        let environment = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate))
        try await render(environment, mode: .light, name: "shell-light-sidebar-toast") { router, _ in
            router.isLabelSidebarVisible = true
            router.perform(.nextThread)
            router.perform(.nextThread)
            router.perform(.markDone)
            try await until { environment.notices.toasts.contains { $0.style == .undo } }
            router.perform(.nextThread)
        }
    }

    @Test func darkOfflineOnTheSecondAccount() async throws {
        let environment = AppEnvironment.fake(corpus: .small, options: .init(liveConnectivity: true))
        let store = try #require(environment.data as? FakeMailStore)
        try await render(environment, mode: .dark, name: "shell-dark-offline") { router, _ in
            router.perform(.switchToAccount(2))
            try await until { router.list?.state == .loaded }
            store.setOffline(true)
            try await until { router.banner()?.kind == .offline }
        }
    }

    @Test func readOnlyRefusesMarkDone() async throws {
        let environment = AppEnvironment.fake(corpus: .small, options: .init(safeMode: .readOnly))
        try await render(environment, mode: .light, name: "shell-read-only") { router, _ in
            router.perform(.markDone)
            router.go(to: .system(.starred))
            try await until { router.list?.state == .loaded }
        }
    }

    @Test func conversationWithTheSequenceHint() async throws {
        let environment = AppEnvironment.fake(corpus: .small)
        try await render(environment, mode: .light, name: "shell-reader-g-hint") { router, content in
            router.perform(.openThread)
            try await until { router.reader?.state == .loaded }
            router.sequenceHint = "G…"
        }
    }
}
