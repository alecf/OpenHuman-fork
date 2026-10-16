import Foundation
import OpenHumanAI
import OpenHumanAITesting
import Testing
@testable import MailFeatures

@MainActor
@Suite struct AIActivityModelTests {
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)) ?? UUID()
    }

    static func trace(_ n: Int, feature: AIFeature = .rewrite, minutesAgo: Int = 0, rating: Int? = nil,
                      cache: AITraceCacheUse = .miss, outcome: AITraceOutcome = .completed,
                      location: AIDataLocation = .onDevice, text: Bool = true, trigger: AITrigger = .user) -> AITraceRecord {
        AITraceRecord(
            id: id(n), createdAt: fixedNow.addingTimeInterval(TimeInterval(-60 * minutesAgo)), feature: feature,
            task: .rewrite, trigger: trigger, accountKeys: ["acct-a"], threadKey: "thread-\(n)",
            promptID: PromptID("rewrite.instruct", version: 2), overrideRevision: 3, providerID: .fake,
            providerName: "Scripted model", model: "scripted-1", dataLocation: location,
            systemText: text ? "Rewrite the draft as asked. ‹nonce›" : nil,
            inputText: text ? "Draft: see you at the harbour office on Tuesday" : nil,
            outputText: text ? "See you at the harbour office on Tuesday." : nil,
            finalText: text ? "See you at the harbour office on Tuesday." : nil,
            steps: [AITraceStep(.conversationShortened, detail: "kept 2 of 5 messages")],
            countedInputTokens: 150, usage: AIUsage(inputTokens: 120, outputTokens: 40), latencyMilliseconds: 850,
            firstTokenMilliseconds: 120, cache: cache, outcome: outcome,
            errorKind: outcome == .failed ? "timeout" : nil, errorText: outcome == .failed ? "The model took too long" : nil,
            rating: rating)
    }

    static func model(_ traces: [AITraceRecord]) -> (AIActivityModel, InMemoryAITraceStore) {
        let store = InMemoryAITraceStore(traces)
        let center = AICenter.make(registry: ProviderRegistry(providers: [ScriptedProvider()]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore()), traces: store)
        return (AIActivityModel(center: center), store)
    }

    @Test func rowsShowTheFeatureModelNumbersAndMarksNewestFirst() async throws {
        let (model, _) = Self.model([
            Self.trace(1, minutesAgo: 30, rating: 1),
            Self.trace(2, feature: .askInbox, minutesAgo: 20, cache: .hit, outcome: .cached),
            Self.trace(3, feature: .summarize, minutesAgo: 10, outcome: .failed),
        ])
        await model.refresh()
        #expect(model.rows.map(\.id) == [Self.id(3), Self.id(2), Self.id(1)])
        let rewrite = try #require(model.rows.last)
        #expect(rewrite.feature == "Write and rewrite (⌘J in a draft)")
        #expect(rewrite.model == "scripted-1 · Scripted model")
        #expect(rewrite.numbers == "120 tokens in · 40 out · 850 ms")
        #expect(rewrite.rating == 1 && !rewrite.cacheHit && !rewrite.failed)
        #expect(rewrite.badge.title == "On this Mac" && rewrite.badge.traceID == Self.id(1))
        #expect(model.rows[1].cacheHit && model.rows[1].feature == "Ask AI (⌘J in the mail list)")
        #expect(model.rows[0].failed && !model.rows[0].numbers.contains("Failed"), "a failure is a mark, not a number")
        #expect(model.rows[0].feature == "Conversation summary")
        #expect(model.summary == "3 requests · none left this Mac")
    }

    @Test func requestsThatLeftTheMacAreCounted() async {
        let (model, _) = Self.model([Self.trace(1), Self.trace(2, location: .thirdParty(vendor: "Anthropic"))])
        await model.refresh()
        #expect(model.summary == "2 requests · 1 left this Mac")
        #expect(model.rows.first { $0.id == Self.id(2) }?.badge.leavesMac == true)
    }

    @Test func feedbackShowsRatedAnswersAndCanShowOnlyThumbsDown() async {
        let (model, _) = Self.model([
            Self.trace(1, minutesAgo: 3, rating: 1), Self.trace(2, minutesAgo: 2),
            Self.trace(3, minutesAgo: 1, rating: -1),
        ])
        model.page = .feedback
        await model.refresh()
        #expect(model.rows.map(\.id) == [Self.id(3), Self.id(1)])
        #expect(model.summary == "2 rated · none left this Mac")
        #expect(model.rows.first?.snippet == "See you at the harbour office on Tuesday.", "a rated row shows what was rated")
        model.onlyThumbsDown = true
        await model.refresh()
        #expect(model.rows.map(\.id) == [Self.id(3)])
        model.page = .requests
        await model.refresh()
        #expect(model.rows.count == 3, "the thumbs filter belongs to the feedback page")
    }

    @Test func aRatingMadeAfterLoadingShowsOnTheNextRefresh() async throws {
        let (model, store) = Self.model([Self.trace(1)])
        model.page = .feedback
        await model.refresh()
        #expect(model.rows.isEmpty && model.emptyText.contains("thumbs"))
        try await store.setRating(Self.id(1), rating: -1)
        await model.refresh()
        #expect(model.rows.map(\.rating) == [-1])
    }

    @Test func openingATraceShowsEverythingSentAndWhyThisModel() async throws {
        let (model, _) = Self.model([Self.trace(1, rating: -1)])
        await model.open(Self.id(1))
        let detail = try #require(model.detail)
        #expect(detail.title == "Write and rewrite (⌘J in a draft)" && detail.rating == -1)
        let facts = Dictionary(uniqueKeysWithValues: detail.facts.map { ($0.key, $0.value) })
        #expect(facts["why"] == "Mail's default for this feature.")
        #expect(facts["prompt"] == "Rewrite (⌘J) prompt, version 2 · your edit, revision 3")
        #expect(facts["time"] == "850 ms, first words after 120 ms")
        #expect(facts["tokens"] == "120 tokens in · 40 out")
        #expect(facts["rating"] == "Thumbs down")
        #expect(detail.sections.map(\.id) == ["output", "steps", "prompt", "input"],
                "the answer comes first; the shown text equals the output, so it isn't repeated")
        #expect(detail.sections.first { $0.id == "input" }?.text.contains("harbour office") == true)
        #expect(detail.sections.first { $0.id == "steps" }?.title == "What Mail did")
        #expect(detail.sections.first { $0.id == "steps" }?.text
            == "Before the model\n• Shortened the conversation to fit the model: kept 2 of 5 messages")
        #expect(detail.promptName == "rewrite.instruct")
        #expect(!detail.whyThisFacts.contains { $0.key == "where" }, "the popover badge already says where")
        model.closeDetail()
        #expect(model.detail == nil)
    }

    @Test func aFailedTraceLeadsWithItsErrorAndATextlessTraceSaysSo() {
        let failed = AITraceDetail(Self.trace(1, outcome: .failed))
        #expect(failed.sections.first?.id == "error" && failed.sections.first?.text == "[timeout] The model took too long")
        let textless = AITraceDetail(Self.trace(2, text: false))
        #expect(textless.sections.map(\.id) == ["steps", "text"])
    }

    @Test func whyThisNamesTheCurrentModelWhenItChangedSinceTheAnswer() async throws {
        var old = Self.trace(1)
        old.providerID = .agentClaude
        old.providerName = "Claude Code"
        let (model, _) = Self.model([old])
        await model.open(Self.id(1))
        let why = try #require(model.detail?.facts.first { $0.key == "why" }?.value)
        #expect(why == "This feature now uses Scripted model. Mail's default for this feature.")
    }

    @Test func deleteAndClearAllRemoveTraces() async {
        let (model, store) = Self.model([Self.trace(1, minutesAgo: 2), Self.trace(2, minutesAgo: 1)])
        await model.refresh()
        #expect(model.keepsAny)
        await model.open(Self.id(2))
        await model.delete(Self.id(2))
        #expect(model.detail == nil && model.rows.map(\.id) == [Self.id(1)])
        await model.clearAll()
        #expect(model.rows.isEmpty && !model.keepsAny)
        #expect(((try? await store.recent(limit: 10)) ?? [Self.trace(9)]).isEmpty)
    }

    @Test func retentionControlsWriteTheTraceSettings() {
        let (model, _) = Self.model([])
        #expect(model.keepDays == 30 && model.perFeatureLimit == 500 && model.maxBytes == 250_000_000)
        model.keepDays = 7
        model.perFeatureLimit = 100
        model.maxBytes = 50_000_000
        model.setKeeps(.classify, false)
        let settings = model.center.settings.traces
        #expect(settings.keepDays == 7 && settings.perFeatureLimit == 100 && settings.maxBytes == 50_000_000)
        #expect(settings.disabledFeatures == [.classify] && !model.keeps(.classify) && model.keeps(.rewrite))
        #expect(!settings.records(.classify) && settings.records(.rewrite))
        model.keepsTraces = false
        #expect(!model.center.settings.traces.enabled && !model.center.settings.traces.records(.rewrite))
        model.setKeeps(.classify, true)
        #expect(model.center.settings.traces.disabledFeatures.isEmpty)
        #expect(AIActivityModel.days(1) == "1 day" && AIActivityModel.days(365) == "1 year")
        #expect(AIActivityModel.size(250_000_000) == "250 MB" && AIActivityModel.size(1_000_000_000) == "1 GB")
    }

    @Test func theListShowsWhatYouAskedForFirstAndBackgroundIsOneChoiceAway() async {
        let (model, _) = Self.model([
            Self.trace(1, feature: .summarize, minutesAgo: 1, trigger: .automatic),
            Self.trace(2, minutesAgo: 2),
            Self.trace(3, feature: .askInbox, minutesAgo: 3),
            Self.trace(4, feature: .replyOptions, minutesAgo: 4, trigger: .automatic),
        ])
        await model.refresh()
        #expect(model.filter == .askedFor && model.rows.map(\.id) == [Self.id(2), Self.id(3)])
        model.filter = .background
        await model.refresh()
        #expect(model.rows.map(\.id) == [Self.id(1), Self.id(4)])
        model.filter = .commandJ
        await model.refresh()
        #expect(model.rows.map(\.id) == [Self.id(2), Self.id(3)])
        model.filter = .quickReplies
        await model.refresh()
        #expect(model.rows.map(\.id) == [Self.id(4)])
        model.filter = .all
        await model.refresh()
        #expect(model.rows.count == 4 && model.backTitle == "All requests")
    }

    @Test func busyBackgroundWorkNeverPushesARatingOrAHandRequestOutOfView() async {
        var traces = (10..<(10 + AIActivityModel.displayLimit + 5)).map {
            Self.trace($0, feature: .summarize, minutesAgo: 0, trigger: .automatic)
        }
        traces.append(Self.trace(1, minutesAgo: 600, rating: -1))
        let (model, _) = Self.model(traces)
        model.filter = .all
        await model.refresh()
        #expect(model.hasMore && model.rows.count == AIActivityModel.displayLimit)
        #expect(!model.rows.contains { $0.id == Self.id(1) })
        #expect(model.summary.hasPrefix("Newest \(AIActivityModel.displayLimit) shown"))
        model.filter = .askedFor
        await model.refresh()
        #expect(model.rows.map(\.id) == [Self.id(1)])
        model.page = .feedback
        await model.refresh()
        #expect(model.rows.map(\.id) == [Self.id(1)], "ratings come from the store, not the newest page")
    }

    @Test func longPromptAndInputCollapseButTheAnswerDoesNot() {
        var long = Self.trace(1)
        long.inputText = (1...30).map { "Message \($0) about the harbour office" }.joined(separator: "\n")
        long.systemText = String(repeating: "Answer from the emails given. ", count: 40)
        long.outputText = (1...20).map { "Line \($0)" }.joined(separator: "\n")
        long.finalText = long.outputText
        let detail = AITraceDetail(long)
        let sections = Dictionary(uniqueKeysWithValues: detail.sections.map { ($0.id, $0) })
        #expect(sections["input"]?.collapses == true && sections["input"]?.lineCount == 30)
        #expect(sections["prompt"]?.collapses == true, "one long line collapses too")
        #expect(sections["output"]?.collapses == false)
        #expect(AITraceDetail(Self.trace(2)).sections.allSatisfy { !$0.collapses })
    }

    @Test func aOneLineSummaryIsNamedAsSuch() {
        var line = Self.trace(1, feature: .summarize, trigger: .automatic)
        line.promptID = PromptID("summarize.line", version: 1)
        #expect(AIActivityModel.row(line).feature == "One-line summary")
        #expect(AITraceDetail(line).title == "One-line summary")
    }

    @Test func withoutATraceStoreTheTabHasNothingToShow() async {
        let center = AICenter.make(registry: ProviderRegistry(providers: [ScriptedProvider()]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore()))
        let model = AIActivityModel(center: center)
        await model.refresh()
        #expect(!model.isAvailable && model.rows.isEmpty)
    }
}
