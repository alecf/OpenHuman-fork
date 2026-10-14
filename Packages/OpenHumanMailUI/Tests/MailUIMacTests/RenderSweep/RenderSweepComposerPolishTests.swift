import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanAI
import OpenHumanAITesting
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func replyAttachedSendDone(_ theme: SweepTheme) async throws {
        let center = AICenter.make(registry: ProviderRegistry(providers: [ScriptedProvider()]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore(AISettings())))
        let environment = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate),
                                              featureFlags: FeatureFlags(), ai: center)
        let settings = try #require(environment.settings, "the fake environment has a settings store")
        try await settings.set(AppSettings.sendAndMarkDone, true)
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let (thread, messages) = try await w.longestConversation()
        let model = try await w.open(thread)
        let middle = messages[messages.count - 2]
        model.reveal(middle.id)
        model.focus(middle.id)
        #expect(w.router.perform(.reply))
        _ = try await w.inlineComposer()
        let editor = try #require(w.editors.first)
        editor.insertText("Thursday at 10 works for me. I'll bring the draft agenda.", replacementRange: editor.selectedRange())
        try await sweepShoot(w.window, screen: "reader-reply-attached-send-done", theme: theme)
    }
}
