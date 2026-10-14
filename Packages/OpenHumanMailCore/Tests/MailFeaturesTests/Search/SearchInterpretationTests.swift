import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private final class PlannerLog: Sendable {
    private let state = Mutex<(asked: [String], held: Set<String>)>(([], []))
    func record(_ text: String) { state.withLock { $0.asked.append(text) } }
    var asked: [String] { state.withLock { $0.asked } }
    func hold(_ text: String) { state.withLock { _ = $0.held.insert(text) } }
    func release(_ text: String) { state.withLock { _ = $0.held.remove(text) } }
    func isHeld(_ text: String) -> Bool { state.withLock { $0.held.contains(text) } }
}

@MainActor
private func interpretation(enabled: Bool = true, available: Bool = true, log: PlannerLog,
                            answer: @escaping @Sendable (String) throws -> SearchPlan = { _ in SearchPlan(keywords: ["invoice"]) })
    -> SearchInterpretation {
    let source = SearchPlanSource(
        isEnabled: { enabled }, isModelAvailable: { _ in available },
        plan: { text, _ in
            log.record(text)
            while log.isHeld(text) { try await Task.sleep(for: .milliseconds(5)) }
            return try answer(text)
        })
    let model = SearchInterpretation(source: source)
    model.delay = .zero
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    model.resolver = SearchPlanResolver(calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    model.now = { Date(timeIntervalSince1970: 1_791_720_000) }
    return model
}

private let context = SearchInterpretation.Context(account: AccountID(1), accountKey: "work", labels: [],
                                                   contacts: { _ in [] })
private let sentence = "invoices from Sarah last month"

@MainActor
@Suite struct SearchInterpretationTests {
    @Test func theRowIsOfferedOnlyForTextThatReadsAsASentence() {
        #expect(SearchInterpretation.readsAsSentence(sentence))
        #expect(SearchInterpretation.readsAsSentence("receipts this week"), "a cue word with three words")
        #expect(SearchInterpretation.readsAsSentence("the big blue house thing"), "five words without a cue")
        #expect(!SearchInterpretation.readsAsSentence("big blue house"), "three words, no cue")
        #expect(!SearchInterpretation.readsAsSentence("invoice"))
        #expect(!SearchInterpretation.readsAsSentence("from:dana invoice last month"), "an operator: exact intent")
        #expect(!SearchInterpretation.readsAsSentence("category:updates mail from last week"))
        #expect(!SearchInterpretation.readsAsSentence(#""exact phrase" from last week"#), "a quote: exact intent")
        #expect(!SearchInterpretation.readsAsSentence("-lunch launch this week"), "a negation")
    }

    @Test func aReadyRowIsAcceptedWithTab() async throws {
        let log = PlannerLog()
        let model = interpretation(log: log)
        model.textChanged(sentence, context: context)
        await eventually { model.state != .hidden && model.state != .waiting }
        guard case .ready(let plan) = model.state else {
            Issue.record("expected a ready row, got \(model.state)")
            return
        }
        #expect(plan.canonicalText == "invoice")
        #expect(model.accept() == "invoice")
        #expect(model.state == .hidden)
        #expect(model.accept() == nil, "nothing to accept once used")
    }

    @Test func aKeystrokeCancelsAndAnOlderAnswerIsDropped() async throws {
        let log = PlannerLog()
        log.hold(sentence)
        let model = interpretation(log: log) { text in SearchPlan(keywords: [text == sentence ? "old" : "new"]) }
        model.textChanged(sentence, context: context)
        await eventually { log.asked.contains(sentence) }
        let newer = sentence + " please"
        model.textChanged(newer, context: context)
        log.release(sentence)
        await eventually { if case .ready = model.state { true } else { false } }
        guard case .ready(let plan) = model.state else { return }
        #expect(plan.canonicalText == "new", "the answer for the older text never shows")
    }

    @Test func escapeHidesTheRowForThisTextOnly() async throws {
        let log = PlannerLog()
        let model = interpretation(log: log)
        model.textChanged(sentence, context: context)
        await eventually { if case .ready = model.state { true } else { false } }
        model.dismiss()
        #expect(model.state == .hidden)
        model.textChanged(sentence, context: context)
        #expect(model.state == .hidden, "the same text stays dismissed")
        model.textChanged(sentence + " now", context: context)
        await eventually { if case .ready = model.state { true } else { false } }
    }

    @Test func aFailureOrASlowAnswerRemovesTheRow() async throws {
        let failing = PlannerLog()
        let refused = interpretation(log: failing) { _ in throw AIError.refused }
        refused.textChanged(sentence, context: context)
        await eventually { failing.asked.count == 1 && refused.state == .hidden }

        let slow = PlannerLog()
        slow.hold(sentence)
        let late = interpretation(log: slow)
        late.timeout = .milliseconds(50)
        late.textChanged(sentence, context: context)
        await eventually { late.state == .waiting }
        await eventually { late.state == .hidden }
        slow.release(sentence)
    }

    @Test func plansAreCachedForTheSession() async throws {
        let log = PlannerLog()
        let model = interpretation(log: log)
        model.textChanged(sentence, context: context)
        await eventually { if case .ready = model.state { true } else { false } }
        model.textChanged("", context: context)
        #expect(model.state == .hidden)
        model.textChanged(sentence, context: context)
        guard case .ready = model.state else {
            Issue.record("a cached plan shows at once")
            return
        }
        #expect(log.asked.count == 1)
    }

    @Test func nothingRunsWhenOffOrWithoutAModel() async throws {
        let off = PlannerLog()
        let disabled = interpretation(enabled: false, log: off)
        disabled.textChanged(sentence, context: context)
        #expect(disabled.state == .hidden)
        let noModel = PlannerLog()
        let unavailable = interpretation(available: false, log: noModel)
        unavailable.textChanged(sentence, context: context)
        disabled.textChanged(sentence, context: nil)
        let nothing = SearchInterpretation(source: nil)
        nothing.textChanged(sentence, context: context)
        #expect(nothing.state == .hidden)
        await eventually { unavailable.state == .hidden }
        #expect(off.asked.isEmpty)
        #expect(noModel.asked.isEmpty)
    }
}

@MainActor
@Suite struct SearchModelInterpretationTests {
    nonisolated static let planJSON = #"{"keywords":["invoice"],"from":[],"to":[],"timeframe":"none","mailbox":"any"}"#

    private func environment(flags: FeatureFlags = FeatureFlags(), settings: AISettings = AISettings())
        -> (AppEnvironment, ScriptedProvider) {
        let provider = ScriptedProvider(id: .appleSystem) { _, _ in .text(Self.planJSON) }
        let center = AICenter.make(registry: ProviderRegistry(providers: [provider]), settings: AISettingsBox(store: InMemoryAISettingsStore(settings)))
        let env = AppEnvironment.fake(corpus: .make(threadCount: 10, now: fixedNow), options: .init(remoteAck: .immediate),
                                      featureFlags: flags, ai: center)
        env.router.start()
        return (env, provider)
    }

    private func ready(_ search: SearchModel) -> Bool {
        if case .ready = search.interpretation.state { true } else { false }
    }

    @Test func tabUsesTheInterpretationAndEnterRunsTheTypedText() async throws {
        let (env, provider) = environment()
        await eventually { env.router.active != nil }
        let search = env.overlays.search
        search.liveDelay = nil
        search.interpretation.delay = .zero
        search.open()
        search.text = sentence
        await eventually { ready(search) }
        #expect(provider.requests.first?.untrusted.isEmpty == true, "the model sees the words, never email text")

        search.submit()
        #expect(env.router.active?.location == .search(sentence))

        search.text = sentence + " again"
        await eventually { ready(search) }
        #expect(search.acceptInterpretation())
        #expect(search.text == "invoice")
        #expect(env.router.active?.location == .search("invoice"))
        #expect(search.recents.first == "invoice")
    }

    @Test func escapeHidesTheRowBeforeClearingTheText() async throws {
        let (env, _) = environment()
        await eventually { env.router.active != nil }
        let search = env.overlays.search
        search.liveDelay = nil
        search.interpretation.delay = .zero
        search.open()
        search.text = sentence
        await eventually { ready(search) }
        search.escape()
        #expect(search.interpretation.state == .hidden)
        #expect(search.text == sentence, "the first Esc hides the row only")
        search.escape()
        #expect(search.text.isEmpty)
    }

    @Test func theModuleTheAISwitchAndTheSettingEachTurnItOff() async throws {
        var off = AISettings()
        off.smartSearch.understandSentences = false
        for (flags, settings) in [(FeatureFlags().with(.smartSearch, false), AISettings()), (FeatureFlags(), AISettings(enabled: false)),
                                  (FeatureFlags(), off)] {
            let (env, provider) = environment(flags: flags, settings: settings)
            await eventually { env.router.active != nil }
            let search = env.overlays.search
            search.liveDelay = nil
            search.interpretation.delay = .zero
            search.open()
            search.text = sentence
            #expect(search.interpretation.state == .hidden)
            #expect(provider.requests.isEmpty)
        }
    }
}
