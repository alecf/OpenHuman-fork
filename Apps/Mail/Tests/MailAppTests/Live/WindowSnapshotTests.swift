import AppKit
import MailFakes
import OpenHumanGmailTesting
import OpenHumanStore
import SwiftUI
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct WindowSnapshotTests {
    @Test func windowOverFakeGmail() async throws {
        let corpus = FakeCorpus.make(threadCount: 60)
        let gmail = FakeGmail(accountEmail: corpus.account.email)
        await FakeGmailLaunch.seed(gmail, corpus: corpus)
        let running = try FakeGmailLaunch.makeSession(store: try MailStore.openInMemoryForTesting(), gmail: gmail)
        let environment = running.session.environment
        await running.session.start()
        let hosting = NSHostingController(rootView: MailWindowView(environment: environment))
        let frame = NSRect(x: -5000, y: -5000, width: 1360, height: 860)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        await eventually("synced") { environment.status.syncText(now: Date())?.hasPrefix("Synced") == true }
        try await Task.sleep(for: .milliseconds(500))
        let view = try #require(window.contentView)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] ?? "/tmp")
        try png.write(to: dir.appendingPathComponent("window-fake-gmail.png"))
        window.orderOut(nil)
        await running.session.stop()
    }
}
