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
    static let askID = id(2)

    static func at(minutesAgo: Int) -> Date { SweepClock.now.addingTimeInterval(TimeInterval(-60 * minutesAgo)) }

    static let names = ["Robin Vale", "Sam Ortiz", "Kit Moreau"]

    static func message(_ n: Int) -> String {
        let sender = names[n % names.count]
        let address = sender.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com"
        return "From: \(sender) <\(address)>\nMessage \(n) about the harbour office walkthrough: floor plans, keys and the "
            + "loading dock schedule for the week."
    }

    static let rewrite = AITraceRecord(
        id: rewriteID, createdAt: at(minutesAgo: 4), feature: .rewrite, task: .rewrite, trigger: .user,
        accountKeys: ["sweep"], threadKey: "t-harbour", promptID: PromptID("rewrite.instruct", version: 2),
        providerID: .appleSystem, providerName: "Apple Intelligence", dataLocation: .onDevice,
        systemText: "Rewrite the user's draft as they ask. Keep their meaning and facts. Reply in the draft's language.\n<email_data nonce=\"\(AITraceRecord.nonceStandIn)\">…</email_data>",
        inputText: "Conversation (newest first)\n" + (5...7).reversed().map(message).joined(separator: "\n\n")
            + "\n\nDraft\nthursday works, ill bring the floor plans\n\nInstruction\nImprove writing",
        outputText: "Thursday at 10 works for me. I'll bring the floor plans.",
        finalText: "Thursday at 10 works for me. I'll bring the floor plans.",
        steps: [AITraceStep(.conversationShortened, detail: "kept the 3 newest of 7 messages")],
        countedInputTokens: 412, usage: AIUsage(inputTokens: 398, outputTokens: 17), latencyMilliseconds: 1_430,
        firstTokenMilliseconds: 380, cache: .miss, outcome: .completed, rating: -1)

    static let longAsk = AITraceRecord(
        id: askID, createdAt: at(minutesAgo: 9), feature: .askInbox, task: .askInbox, trigger: .user,
        accountKeys: ["sweep"], promptID: PromptID("ask.inbox", version: 1), overrideRevision: 3,
        providerID: .agentClaude, providerName: "Claude Code", dataLocation: .thirdParty(vendor: "Anthropic"),
        systemText: "Answer the question using only the emails given.\n" + String(repeating: "Cite each email you use.\n", count: 12),
        inputText: "Question\nWhen is each invoice from the print shop due, and which ones did I already pay?\n\n"
            + (1...30).map(message).joined(separator: "\n\n"),
        outputText: "Two invoices are open: the poster run is due Friday and the flyer reprint on the 28th. The banner "
            + "invoice was paid last week.\nSources: 4, 11, 19",
        finalText: "Two invoices are open: the poster run is due Friday and the flyer reprint on the 28th. The banner "
            + "invoice was paid last week.",
        steps: [AITraceStep(.sourcesLineRemoved)],
        countedInputTokens: 9_840, usage: AIUsage(inputTokens: 9_612, outputTokens: 61), latencyMilliseconds: 7_900,
        cache: .miss, outcome: .completed, rating: 1)

    static let all: [AITraceRecord] = [
        rewrite,
        longAsk,
        AITraceRecord(id: id(3), createdAt: at(minutesAgo: 15), feature: .summarize, task: .summarize, trigger: .user,
                      promptID: PromptID("summarize.thread", version: 3), providerID: .appleSystem,
                      providerName: "Apple Intelligence", dataLocation: .onDevice, cache: .hit, outcome: .cached),
        AITraceRecord(id: id(4), createdAt: at(minutesAgo: 22), feature: .replyOptions, task: .replyOptions,
                      trigger: .user, promptID: PromptID("reply.options", version: 2), providerID: .appleSystem,
                      providerName: "Apple Intelligence", dataLocation: .onDevice,
                      outputText: "Sounds good, see you then.", finalText: "Sounds good, see you then.",
                      countedInputTokens: 640, latencyMilliseconds: 940, cache: .miss, outcome: .completed, rating: 1),
        AITraceRecord(id: id(5), createdAt: at(minutesAgo: 31), feature: .rewrite, task: .rewrite, trigger: .user,
                      promptID: PromptID("rewrite.instruct", version: 2), providerID: .appleSystem,
                      providerName: "Apple Intelligence", dataLocation: .onDevice, countedInputTokens: 2_210,
                      latencyMilliseconds: 20_000, cache: .miss, outcome: .failed, errorKind: "timeout",
                      errorText: "The model took too long"),
        AITraceRecord(id: id(6), createdAt: at(minutesAgo: 40), feature: .summarize, task: .summarize, trigger: .automatic,
                      promptID: PromptID("summarize.line", version: 1), providerID: .appleSystem,
                      providerName: "Apple Intelligence", dataLocation: .onDevice, countedInputTokens: 880,
                      latencyMilliseconds: 610, cache: .miss, outcome: .completed),
    ]

    @MainActor static func center(_ traces: [AITraceRecord] = all) -> AICenter {
        let claude = ScriptedProvider(id: .agentClaude, displayName: "Claude Code",
                                      capabilities: .fake(dataLocation: .thirdParty(vendor: "Anthropic")))
        return AICenter.make(registry: ProviderRegistry(providers: [
            ScriptedProvider(id: .appleSystem, displayName: "Apple Intelligence"),
        ]), settings: AISettingsBox(store: InMemoryAISettingsStore()), traces: InMemoryAITraceStore(traces),
        makeProvider: { id in id == .agentClaude ? claude : nil })
    }
}

extension RenderSweepTests {
    static let settingsContentWidth: CGFloat = SettingsMetrics.windowWidth - SettingsMetrics.sidebarWidth - 65

    @MainActor static func settingsWidth(_ store: ThemeStore) -> CGFloat {
        settingsContentWidth + 2 * CGFloat(store.resolved.space8)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func aiActivityFeedbackAndTraceDetail(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let width = Self.settingsWidth(store)
        let activity = AIActivityModel(center: SweepAITraces.center())
        let page = { AnyView(SettingsPageScaffold(title: "AI") { AIActivityView(model: activity) }) }

        activity.filter = .all
        await activity.refresh()
        let list = sweepStandaloneWindow(page(), store: store, size: NSSize(width: width, height: 1300))
        defer { list.orderOut(nil) }
        try await sweepShoot(list, screen: "settings-ai-activity", theme: theme, settle: .milliseconds(600))

        activity.filter = .askedFor
        await activity.refresh()
        let asked = sweepStandaloneWindow(page(), store: store, size: NSSize(width: width, height: 760))
        defer { asked.orderOut(nil) }
        try await sweepShoot(asked, screen: "settings-ai-activity-asked", theme: theme, settle: .milliseconds(600))

        activity.page = .feedback
        await activity.refresh()
        let feedback = sweepStandaloneWindow(page(), store: store, size: NSSize(width: width, height: 760))
        defer { feedback.orderOut(nil) }
        try await sweepShoot(feedback, screen: "settings-ai-feedback", theme: theme, settle: .milliseconds(600))

        activity.onlyThumbsDown = true
        await activity.refresh()
        let down = sweepStandaloneWindow(page(), store: store, size: NSSize(width: width, height: 640))
        defer { down.orderOut(nil) }
        try await sweepShoot(down, screen: "settings-ai-feedback-thumbs-down", theme: theme, settle: .milliseconds(600))

        await activity.open(SweepAITraces.rewriteID)
        let detail = sweepStandaloneWindow(page(), store: store, size: NSSize(width: width, height: 1300))
        defer { detail.orderOut(nil) }
        try await sweepShoot(detail, screen: "settings-ai-trace-detail", theme: theme, settle: .milliseconds(600))

        await activity.open(SweepAITraces.askID)
        let long = sweepStandaloneWindow(page(), store: store, size: NSSize(width: width, height: 1300))
        defer { long.orderOut(nil) }
        try await sweepShoot(long, screen: "settings-ai-trace-detail-long", theme: theme, settle: .milliseconds(600))
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func aiActivityEmptyStates(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let width = Self.settingsWidth(store)
        let activity = AIActivityModel(center: SweepAITraces.center([]))
        await activity.refresh()
        let page = { AnyView(SettingsPageScaffold(title: "AI") { AIActivityView(model: activity) }) }
        let requests = sweepStandaloneWindow(page(), store: store, size: NSSize(width: width, height: 520))
        defer { requests.orderOut(nil) }
        try await sweepShoot(requests, screen: "settings-ai-activity-empty", theme: theme, settle: .milliseconds(600))

        activity.page = .feedback
        await activity.refresh()
        let feedback = sweepStandaloneWindow(page(), store: store, size: NSSize(width: width, height: 520))
        defer { feedback.orderOut(nil) }
        try await sweepShoot(feedback, screen: "settings-ai-feedback-empty", theme: theme, settle: .milliseconds(600))
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func aiFeatureModelsAtSettingsWidth(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let width = Self.settingsWidth(store)
        let center = SweepAITraces.center()
        let section = AnyView(SettingsPageScaffold(title: "AI") { AIFeatureModelsSection(center: center) })
        let window = sweepStandaloneWindow(section, store: store, size: NSSize(width: width, height: 900))
        defer { window.orderOut(nil) }
        try await sweepShoot(window, screen: "settings-ai-feature-models", theme: theme, settle: .milliseconds(800))
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func aiWhyThisAndModelPopovers(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let center = SweepAITraces.center()
        let why = await center.whyLine(for: SweepAITraces.rewrite)
        let detail = AITraceDetail(SweepAITraces.rewrite, why: why)

        let whyThis = sweepStandaloneWindow(AITracePopoverFrame { AIWhyThisContent(detail: detail) {} }, store: store,
                                            size: NSSize(width: AIPopoverMetrics.width, height: 400))
        defer { whyThis.orderOut(nil) }
        try await sweepShoot(whyThis, screen: "ai-why-this-popover", theme: theme)

        let choice = AIModelChoiceModel(center: center, feature: .rewrite, accountKey: "sweep")
        await choice.refresh()
        let popover = AITracePopoverFrame {
            AIModelPopoverContent(answerModel: detail.model, answerBadge: detail.badge,
                                  answerFacts: AIComposerModelPopover.numbers(detail), choice: choice, canRerun: true,
                                  hasTrace: true, rerun: {}, openTrace: {})
        }
        let model = sweepStandaloneWindow(popover, store: store, size: NSSize(width: AIPopoverMetrics.width, height: 520))
        defer { model.orderOut(nil) }
        try await sweepShoot(model, screen: "composer-cmdj-model-popover", theme: theme)

        let trace = sweepStandaloneWindow(AITracePopoverFrame {
            AITraceDetailView(detail: detail, backTitle: "Model", back: {})
        }, store: store, size: NSSize(width: AIPopoverMetrics.width, height: AIPopoverMetrics.maxHeight))
        defer { trace.orderOut(nil) }
        try await sweepShoot(trace, screen: "composer-cmdj-model-trace", theme: theme)

        let longDetail = AITraceDetail(SweepAITraces.longAsk, why: await center.whyLine(for: SweepAITraces.longAsk))
        let long = sweepStandaloneWindow(AITracePopoverFrame {
            AITraceDetailView(detail: longDetail, backTitle: "Why this?", back: {})
        }, store: store, size: NSSize(width: AIPopoverMetrics.width, height: AIPopoverMetrics.maxHeight))
        defer { long.orderOut(nil) }
        try await sweepShoot(long, screen: "ai-why-this-trace-long", theme: theme)

        let badge = AIProviderBadge(provenance: AIProvenance(providerID: .appleSystem, providerName: "Apple Intelligence",
                                                             dataLocation: .onDevice, traceID: SweepAITraces.rewriteID))
        let offDevice = AIProviderBadge(providerName: "Claude Code", location: .thirdParty(vendor: "Anthropic"))
        let triggers = VStack(alignment: .leading, spacing: 16) {
            AIComposerModelBadgeLabel(badge: badge)
            AIComposerModelBadgeLabel(badge: offDevice)
            AIWhyThisBadge(badge: badge, center: center, short: true)
        }
        .padding(16)
        let triggersWindow = sweepStandaloneWindow(triggers, store: store, size: NSSize(width: 320, height: 140))
        defer { triggersWindow.orderOut(nil) }
        try await sweepShoot(triggersWindow, screen: "ai-badge-triggers", theme: theme)
    }
}
