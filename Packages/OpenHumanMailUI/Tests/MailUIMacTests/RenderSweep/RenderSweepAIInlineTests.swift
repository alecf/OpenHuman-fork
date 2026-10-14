import AppKit
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

extension RenderSweepTests {
    private static func aiEnvironment(_ provider: ScriptedProvider) async throws -> (AppEnvironment, AICenter) {
        let center = AICenter.make(registry: ProviderRegistry(providers: [provider]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore(
                                       AISettings(draftReplies: .onDeviceAuto))))
        let env = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate),
                                      featureFlags: FeatureFlags(), ai: center)
        env.router.start()
        try await until { env.router.list?.state == .loaded }
        return (env, center)
    }

    private static func needsReplyRow(_ env: AppEnvironment, _ center: AICenter) async throws -> InlineReplyRow {
        let account = try #require(env.router.accounts.first?.account)
        let rows = try await env.data.threadPage(.system(.inbox), account: account.id, after: nil, limit: 200).rows
        for row in rows {
            var newest: MessageKey?
            for try await detail in env.data.threadDetail(row.id) {
                newest = detail?.messages.last?.id
                break
            }
            guard let newest else { continue }
            let inline = center.inlineReplies.row(for: row.id, message: newest)
            inline.appear()
            try await until(timeout: .seconds(60)) { inline.decision != .undecided }
            if inline.decision == .needsReply { return inline }
        }
        Issue.record("no conversation that needs a reply in the fake Inbox")
        throw CancellationError()
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func inlineRepliesWritingAndReady(_ theme: SweepTheme) async throws {
        let size = NSSize(width: 680, height: 120)
        let held = ScriptedProvider { request, _ in
            request.task == .replyOptions ? .hang : FakeAIProvider.cannedScript(request)
        }
        let (heldEnv, heldCenter) = try await Self.aiEnvironment(held)
        let writing = try await Self.needsReplyRow(heldEnv, heldCenter)
        try await until { writing.state == .writing }
        let store = theme.makeStore()
        let first = sweepStandaloneWindow(QuickReplyMessageRow(center: heldCenter, environment: heldEnv,
                                                               thread: writing.thread, message: writing.message)
                                              .padding(16), store: store, size: size)
        defer { first.orderOut(nil) }
        try await sweepShoot(first, screen: "reader-inline-replies-writing", theme: theme)

        let (env, center) = try await Self.aiEnvironment(ScriptedProvider())
        let ready = try await Self.needsReplyRow(env, center)
        try await until { ready.state == .ready }
        ready.next()
        let second = sweepStandaloneWindow(QuickReplyMessageRow(center: center, environment: env, thread: ready.thread,
                                                                message: ready.message)
                                               .padding(16), store: store, size: size)
        defer { second.orderOut(nil) }
        try await sweepShoot(second, screen: "reader-inline-replies-ready", theme: theme)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func cmdJPromptWorkingAndEditBar(_ theme: SweepTheme) async throws {
        let size = NSSize(width: 680, height: 300)
        let store = theme.makeStore()
        let (env, center) = try await Self.aiEnvironment(ScriptedProvider())
        let session = try #require(env.compose.openNew(placement: .modal))
        let prompt = try #require(center.togglePanel(session))
        #expect(prompt.showsExamples)
        let empty = sweepStandaloneWindow(AIComposerPanel(model: prompt, center: center).padding(16), store: store,
                                          size: size)
        defer { empty.orderOut(nil) }
        try await sweepShoot(empty, screen: "composer-cmdj-prompt", theme: theme)

        prompt.instruction = "Write a short hello"
        prompt.generate()
        try await until { prompt.phase == .done }
        let edit = sweepStandaloneWindow(AIComposerPanel(model: prompt, center: center).padding(16), store: store,
                                         size: size)
        defer { edit.orderOut(nil) }
        try await sweepShoot(edit, screen: "composer-cmdj-edit-bar", theme: theme)
        env.compose.close(session)

        let hanging = ScriptedProvider { request, _ in
            request.task == .rewrite ? .hang : FakeAIProvider.cannedScript(request)
        }
        let (heldEnv, heldCenter) = try await Self.aiEnvironment(hanging)
        let other = try #require(heldEnv.compose.openNew(placement: .modal))
        let working = try #require(heldCenter.togglePanel(other))
        working.instruction = "Write a short hello"
        working.generate()
        try await until { working.phase == .working }
        let busy = sweepStandaloneWindow(AIComposerPanel(model: working, center: heldCenter).padding(16), store: store,
                                         size: size)
        defer { busy.orderOut(nil) }
        try await sweepShoot(busy, screen: "composer-cmdj-working", theme: theme)
        working.stop()
        heldEnv.compose.close(other)
    }
}
