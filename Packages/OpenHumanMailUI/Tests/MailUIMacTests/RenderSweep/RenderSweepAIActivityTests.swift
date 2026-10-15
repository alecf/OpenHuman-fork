import AppKit
import MailFeatures
import MailTheme
import OpenHumanAI
import OpenHumanAITesting
import SwiftUI
import Testing
@testable import MailUI

enum SweepAITraces {
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)) ?? UUID()
    }

    static let rewriteID = id(1)

    static func at(minutesAgo: Int) -> Date { SweepClock.now.addingTimeInterval(TimeInterval(-60 * minutesAgo)) }

    static let rewrite = AITraceRecord(
        id: rewriteID, createdAt: at(minutesAgo: 4), feature: .rewrite, task: .rewrite, trigger: .user,
        accountKeys: ["sweep"], threadKey: "t-harbour", promptID: PromptID("rewrite.instruct", version: 2),
        providerID: .appleSystem, providerName: "Apple Intelligence", dataLocation: .onDevice,
        systemText: "Rewrite the user's draft as they ask. Keep their meaning and facts. Reply in the draft's language.\n<email_data nonce=\"\(AITraceRecord.nonceStandIn)\">…</email_data>",
        inputText: """
            Conversation (newest first)
            From: Robin Vale <robin@example.com>
            Can we move the harbour office walkthrough to Thursday at 10?

            Draft
            thursday works, ill bring the floor plans

            Instruction
            Improve writing
            """,
        outputText: "Thursday at 10 works for me. I'll bring the floor plans.",
        finalText: "Thursday at 10 works for me. I'll bring the floor plans.",
        steps: [AITraceStep(.conversationShortened, detail: "kept the 3 newest of 7 messages")],
        countedInputTokens: 412, usage: AIUsage(inputTokens: 398, outputTokens: 17), latencyMilliseconds: 1_430,
        firstTokenMilliseconds: 380, cache: .miss, outcome: .completed, rating: -1)

    static let all: [AITraceRecord] = [
        rewrite,
        AITraceRecord(id: id(2), createdAt: at(minutesAgo: 9), feature: .askInbox, task: .askInbox, trigger: .user,
                      promptID: PromptID("ask.inbox", version: 1), providerID: .appleSystem,
                      providerName: "Apple Intelligence", dataLocation: .onDevice, outputText: "The invoice is due Friday.",
                      finalText: "The invoice is due Friday.", countedInputTokens: 980, latencyMilliseconds: 2_120,
                      cache: .miss, outcome: .completed),
        AITraceRecord(id: id(3), createdAt: at(minutesAgo: 15), feature: .summarize, task: .summarize, trigger: .user,
                      promptID: PromptID("summarize.thread", version: 3), providerID: .appleSystem,
                      providerName: "Apple Intelligence", dataLocation: .onDevice, cache: .hit, outcome: .cached),
        AITraceRecord(id: id(4), createdAt: at(minutesAgo: 22), feature: .replyOptions, task: .replyOptions,
                      trigger: .user, promptID: PromptID("reply.options", version: 2), providerID: .appleSystem,
                      providerName: "Apple Intelligence", dataLocation: .onDevice, countedInputTokens: 640,
                      latencyMilliseconds: 940, cache: .miss, outcome: .completed, rating: 1),
        AITraceRecord(id: id(5), createdAt: at(minutesAgo: 31), feature: .summarize, task: .summarize, trigger: .automatic,
                      promptID: PromptID("summarize.line", version: 1), providerID: .appleSystem,
                      providerName: "Apple Intelligence", dataLocation: .onDevice, countedInputTokens: 2_210,
                      latencyMilliseconds: 20_000, cache: .miss, outcome: .failed, errorKind: "timeout",
                      errorText: "The model took too long"),
    ]

    @MainActor static func center() -> AICenter {
        AICenter.make(registry: ProviderRegistry(providers: [
            ScriptedProvider(id: .appleSystem, displayName: "Apple Intelligence"),
        ]), settings: AISettingsBox(store: InMemoryAISettingsStore()), traces: InMemoryAITraceStore(all))
    }
}

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func aiActivityFeedbackAndTraceDetail(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let activity = AIActivityModel(center: SweepAITraces.center())
        await activity.refresh()
        let page = { AnyView(SettingsPageScaffold(title: "AI") { AIActivityView(model: activity) }) }

        let list = sweepStandaloneWindow(page(), store: store, size: NSSize(width: 760, height: 1200))
        defer { list.orderOut(nil) }
        try await sweepShoot(list, screen: "settings-ai-activity", theme: theme, settle: .milliseconds(600))

        activity.page = .feedback
        activity.onlyThumbsDown = true
        let feedback = sweepStandaloneWindow(page(), store: store, size: NSSize(width: 760, height: 900))
        defer { feedback.orderOut(nil) }
        try await sweepShoot(feedback, screen: "settings-ai-feedback", theme: theme, settle: .milliseconds(600))

        await activity.open(SweepAITraces.rewriteID)
        let detail = sweepStandaloneWindow(page(), store: store, size: NSSize(width: 760, height: 1300))
        defer { detail.orderOut(nil) }
        try await sweepShoot(detail, screen: "settings-ai-trace-detail", theme: theme, settle: .milliseconds(600))
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func aiWhyThisAndModelPopovers(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let center = SweepAITraces.center()
        let why = await center.whyLine(for: .rewrite, accountKeys: [nil])
        let detail = AITraceDetail(SweepAITraces.rewrite, why: why)

        let whyThis = sweepStandaloneWindow(AITracePopoverFrame { AIWhyThisContent(detail: detail) {} }, store: store,
                                            size: NSSize(width: AIPopoverMetrics.width, height: 440))
        defer { whyThis.orderOut(nil) }
        try await sweepShoot(whyThis, screen: "ai-why-this-popover", theme: theme)

        let choice = AIModelChoiceModel(center: center, feature: .rewrite, accountKey: nil)
        await choice.refresh()
        let popover = AITracePopoverFrame {
            AIModelPopoverContent(answerModel: detail.model, answerBadge: detail.badge,
                                  answerFacts: AIComposerModelPopover.numbers(detail), choice: choice, canRerun: true,
                                  hasTrace: true, rerun: {}, openTrace: {})
        }
        let model = sweepStandaloneWindow(popover, store: store, size: NSSize(width: AIPopoverMetrics.width, height: 460))
        defer { model.orderOut(nil) }
        try await sweepShoot(model, screen: "composer-cmdj-model-popover", theme: theme)

        let trace = sweepStandaloneWindow(AITracePopoverFrame {
            AITraceDetailView(detail: detail, backTitle: "Model", back: {})
        }, store: store, size: NSSize(width: AIPopoverMetrics.width, height: AIPopoverMetrics.maxHeight))
        defer { trace.orderOut(nil) }
        try await sweepShoot(trace, screen: "composer-cmdj-model-trace", theme: theme)
    }
}
