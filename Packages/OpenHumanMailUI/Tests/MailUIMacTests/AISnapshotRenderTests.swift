import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct AISnapshotRenderTests {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] ?? "/tmp")
    let renderer = SnapshotRenderTests()

    func environment(_ theme: ResolvedTheme = .light) -> (AppEnvironment, AICenter) {
        let center = AICenter.make(registry: ProviderRegistry(providers: [FakeAIProvider(displayName: "Apple on-device model")]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore()))
        let env = AppEnvironment.fake(corpus: .rich(threadCount: 60, now: Date()), options: .init(remoteAck: .immediate),
                                      ai: center)
        return (env, center)
    }

    func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + testBackstop
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func renderTheSummaryLineInTheReader() async throws {
        for (name, theme) in [("ai-reader-summary-light", ResolvedTheme.light), ("ai-reader-summary-dark", .dark)] {
            let (env, center) = environment()
            let router = AppRouter(environment: env)
            let content = MainContentViewController(router: router, theme: theme.tokens)
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1360, height: 860),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = content
            window.setFrame(NSRect(x: -5000, y: -5000, width: 1360, height: 860), display: true)
            window.orderFrontRegardless()
            try await until { router.list?.state == .loaded && router.accounts.count == 2 }
            var opened: ThreadKey?
            for row in router.list?.rows ?? [] {
                for try await detail in env.data.threadDetail(row.id) {
                    if (detail?.messages.count ?? 0) >= 3 { opened = row.id }
                    break
                }
                if opened != nil { break }
            }
            let thread = try #require(opened)
            router.open(thread)
            let summary = center.summary(for: thread)
            try await until { summary.phase == .done }
            try await Task.sleep(for: .milliseconds(400))
            try renderer.snapshot(window, name: name)
            window.close()
        }
    }

    @Test func renderTheCmdJPanel() async throws {
        let (env, center) = environment()
        env.router.start()
        try await until { env.router.list?.state == .loaded && env.router.accounts.count == 2 }
        let manager = env.compose
        let session = try #require(manager.openNew(placement: .modal))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 900, height: 760), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ComposerHostView(manager: manager).environment(\.theme, .light)
            .frame(width: 900, height: 760))
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        let text = try #require(ComposerTests.descendants(of: host).compactMap { $0 as? ComposerTextView }.first)
        text.insertText("I have reviewed the attached figures and they appear correct. Happy to sign off on Q4.",
                        replacementRange: NSRange(location: 0, length: 0))
        text.setSelectedRange(NSRange(location: 0, length: 62))
        let panel = try #require(center.togglePanel(session))
        panel.instruction = "Make it shorter and warmer"
        panel.generate()
        try await until { panel.phase == .done }
        panel.showsDiff = true
        try await Task.sleep(for: .milliseconds(300))
        try renderer.snapshot(window, name: "ai-cmdj-rewrite")
        panel.close()
        manager.close(session)

        let rows = try await env.data.threadPage(.system(.inbox), account: AccountID(1), after: nil, limit: 200).rows
        var replyThread: ThreadKey?
        let me = try #require(env.router.accounts.first { $0.id == AccountID(1) }?.account)
        for row in rows {
            for try await detail in env.data.threadDetail(row.id) {
                if let last = detail?.messages.last, (detail?.messages.count ?? 0) >= 3, !me.isMe(last.from?.email ?? "") {
                    replyThread = row.id
                }
                break
            }
            if replyThread != nil { break }
        }
        let replyKey = try #require(replyThread)
        let reply = try #require(manager.openReply(replyKey, mode: .reply))
        await reply.settle()
        reply.placement = .modal
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let quick = try #require(center.togglePanel(reply))
        try await until { quick.quickReplies?.phase == .ready }
        quick.quickReplies?.select(1)
        try await Task.sleep(for: .milliseconds(300))
        try renderer.snapshot(window, name: "ai-cmdj-quick-replies")
        window.close()
    }

    @Test func renderTheAISettingsSection() async throws {
        let (env, center) = environment()
        env.router.start()
        try await until { env.router.accounts.count == 2 }
        center.summary(for: try #require(env.router.list?.cursor)).summarize(trigger: .user)
        try await until { !center.activity.entries.isEmpty }
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 700, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollView { AISettingsSection(center: center, environment: env).padding(32) }
            .environment(\.theme, .light).frame(width: 700, height: 900).background(Color.white))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(500))
        try renderer.snapshot(window, name: "ai-settings")
        window.close()
    }
}
