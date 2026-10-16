import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

final class ClassifierLog: Sendable {
    private let items = Mutex<[String]>([])
    func add(_ key: String) { items.withLock { $0.append(key) } }
    var all: [String] { items.withLock { $0 } }
}

@MainActor
final class AutoLabelFixture {
    static let work = AccountID(1)
    static let personal = AccountID(2)

    let store: FakeMailStore
    let recorder: RecordingCommands
    let rules: FakeImportanceRules
    let index: InMemoryAutoLabelStore
    let env: AppEnvironment
    let center: AutoLabelCenter
    let log = ClassifierLog()

    init(writes: Bool? = true, isLiveAccount: Bool = false, classifiers: [any AIClassificationProvider]? = nil,
         providers: [any AIProvider] = [], entries: [AutoLabelEntry] = [], sharing existing: FakeMailStore? = nil,
         aiSettings: AISettings = AISettings(),
         verdict: @escaping @Sendable (ClassificationInput) throws -> AutoLabelCategory? = { _ in .marketing }) {
        store = existing ?? FakeMailStore(corpus: .rich(threadCount: 60, now: fixedNow),
                                          options: .init(remoteAck: .immediate, heldSends: .manual, now: { fixedNow }))
        recorder = RecordingCommands(store)
        rules = FakeImportanceRules(corpus: .rich(threadCount: 60, now: fixedNow), now: { fixedNow })
        index = InMemoryAutoLabelStore(entries)
        let log = self.log
        let classifier = FakeClassifier(id: "fake.autolabels", autoLabel: { input in
            log.add(input.threadKey)
            return try verdict(input)
        })
        let registry = ProviderRegistry(providers: providers, classifiers: classifiers ?? [classifier])
        let ai = AICenter.make(registry: registry, settings: AISettingsBox(store: InMemoryAISettingsStore(aiSettings)))
        env = AppEnvironment(data: store, commands: recorder, accounts: store, settings: store, isFake: !isLiveAccount,
                             importance: rules,
                             systemPreferences: SystemPreferences(defaults: UserDefaults(suiteName: "openhuman.test.\(UUID().uuidString)") ?? .standard),
                             onboardingProgress: InMemoryOnboardingProgress(), ai: ai, isLiveAccount: isLiveAccount,
                             keymapStore: InMemoryKeymapStore(), autoLabelStore: index)
        center = env.autoLabels!
        center.options = AutoLabelCenter.Options(writesToGmail: writes, promptVersion: 1, now: { fixedNow },
                                                 backfillDays: 36_500)
        center.onIndexChange = { [weak rules] index in
            rules?.setAutoLabelLookup { key in index.category(account: key.account, thread: key.gmailThreadID, labelIDs: []) }
        }
    }

    func inbox(_ account: AccountID = work) async throws -> [ThreadRow] {
        try await store.threadPage(.system(.inbox), account: account, after: nil, limit: 1_000).rows
    }

    func labels(_ account: AccountID = work) async -> [LabelInfo] {
        await AIThreadLoader.first(store.labels(account)) ?? []
    }

    func labelMap(_ account: AccountID = work) async -> [Int64: LabelInfo] {
        Dictionary((await labels(account)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func ourLabelIDs(_ account: AccountID = work) async -> Set<Int64> {
        Set((await labels(account)).filter { OHGmailLabels.autoLabelCategory(inLabelName: $0.name) != nil }.map(\.id))
    }
}

@MainActor
@Suite struct AutoLabelTests {
    typealias F = AutoLabelFixture

    @Test func recentMailIsSortedOnThisMacAndASecondRunIsACacheHit() async throws {
        let f = F(writes: false)
        #expect(await f.center.classifyRecent() > 0)
        let calls = f.center.modelCalls
        #expect(calls > 0 && f.center.failures == 0)
        let entries = try await f.index.entries(account: F.work)
        #expect(entries.contains {
            $0.source == .model && $0.category == "Marketing" && $0.promptVersion == 1 && $0.modelID == "fake.autolabels|classifier-1"
        })
        await f.center.classifyRecent()
        #expect(f.center.modelCalls == calls, "same thread, newest message, prompt and model: no second model call")
        #expect(f.center.cacheHits >= calls)
        #expect(f.recorder.calls.isEmpty, "with writes off nothing reaches the mail port")
    }

    @Test func aNewPromptVersionClassifiesAgain() async {
        let f = F(writes: false)
        await f.center.classifyRecent()
        let first = f.center.modelCalls
        f.center.options.promptVersion = 2
        await f.center.classifyRecent()
        #expect(first > 0 && f.center.modelCalls == first * 2)
    }

    @Test func waitingIsDerivedWithoutAskingTheModel() async throws {
        let f = F(writes: false)
        await f.center.classifyRecent()
        let waiting = try await f.index.entries(account: F.work).filter { $0.category == "Waiting" }
        #expect(!waiting.isEmpty, "the rich corpus has conversations where the user wrote last")
        #expect(waiting.allSatisfy { $0.source == .derived })
        let asked = Set(f.log.all)
        #expect(waiting.allSatisfy { !asked.contains("\(F.work.rawValue).\($0.thread.rawValue)") })
    }

    @Test func malformedOutputLabelsNothing() async throws {
        let f = F(verdict: { _ in throw AIError.invalidOutput("not JSON") })
        await f.center.classifyRecent()
        #expect(f.center.failures > 0)
        #expect(try await f.index.entries(account: F.work).allSatisfy { $0.source != .model })
        let created = (await f.labels()).compactMap { OHGmailLabels.autoLabelCategory(inLabelName: $0.name) }
        #expect(created.allSatisfy { $0 == "Waiting" }, "no model verdict, no label (Waiting is derived)")
        let g = F(writes: false, verdict: { _ in .waiting })
        await g.center.classifyRecent()
        #expect(try await g.index.entries(account: F.work).allSatisfy { $0.source != .model } && g.center.failures > 0)
    }

    @Test func withoutTheOnDeviceModelTheSwitchSaysWhyAndNothingRuns() async throws {
        let unavailable = FakeClassifier(id: "fake.autolabels", availability: .unavailable(reason: .appleIntelligenceNotEnabled),
                                         autoLabel: { _ in
                                             Issue.record("an unavailable classifier is never asked")
                                             return .marketing
                                         })
        let f = F(classifiers: [unavailable])
        await f.center.refreshAvailability()
        guard case .unavailable(let reason) = f.center.availability else {
            Issue.record("expected unavailable")
            return
        }
        #expect(!reason.isEmpty && !f.center.isOn)
        #expect(await f.center.classifyRecent() == 0 && f.center.modelCalls == 0)
        let settings = AutoLabelSettingsModel(environment: f.env)
        #expect(settings.unavailableText != nil && !settings.canUseSwitch)
        var off = AISettings()
        off.enabled = false
        let g = F(aiSettings: off)
        await g.center.refreshAvailability()
        #expect(!g.center.isOn && g.center.availability != .available)
    }

    @Test func neverACloudModelOrALanguageModel() async throws {
        let cloud = FakeClassifier(id: "cloud.autolabels", dataLocation: .thirdParty(vendor: "Example"), autoLabel: { _ in
            Issue.record("a classifier that leaves the Mac is never asked")
            return .marketing
        })
        let model = ScriptedProvider()
        let f = F(classifiers: [cloud], providers: [model])
        await f.center.refreshAvailability()
        #expect(!f.center.isOn)
        #expect(await f.center.classifyRecent() == 0)
        #expect(model.requests.isEmpty, "auto labels never prompt a language model")
        #expect(f.recorder.calls.isEmpty)
    }

    @Test func removingAnAccountPurgesItsRows() async throws {
        let stale = AutoLabelEntry(account: AccountID(99), thread: GmailThreadID("t-gone"), latestMessage: GmailMessageID("m1"),
                                   promptVersion: 1, modelID: "x", category: "News", source: .model, classifiedAt: fixedNow)
        let mine = AutoLabelEntry(account: F.personal, thread: GmailThreadID("t-personal"), latestMessage: GmailMessageID("m2"),
                                  promptVersion: 1, modelID: "x", category: "Pitch", source: .model, classifiedAt: fixedNow)
        let f = F(writes: false, entries: [stale, mine])
        f.center.start()
        await eventually { f.center.index.threads[F.personal]?.isEmpty == false }
        #expect(try await f.index.accountIDs().contains(AccountID(99)) == false, "rows of an account gone while closed")
        try await f.store.remove(F.personal)
        var tries = 0
        while tries < 2_000, (try? await f.index.accountIDs())?.contains(F.personal) == true {
            tries += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await f.index.accountIDs().contains(F.personal) == false)
        #expect(f.center.index.threads[F.personal] == nil)
    }

    @Test func chipsShowTheCategoryAfterImportanceAndInPlaceOfGmailsCategory() async throws {
        let f = F(writes: false)
        await f.center.classifyRecent()
        let labels = await f.labelMap()
        let row = try #require(try await f.inbox().first { f.center.category(of: $0.id) == "Marketing" })
        let title = f.center.title(for: row, labels: labels)
        #expect(title == "Marketing")
        let chips = ThreadRowFormatting.chips(for: row, context: ThreadRowChipContext(location: .system(.inbox), labels: labels),
                                              autoLabel: title)
        let categories = chips.filter { $0.kind == .category }
        #expect(categories.map(\.title) == ["Marketing"], "one category chip, the auto label")
        if row.isImportant { #expect(chips.first?.kind == .important, "a category never hides importance") }
        try await f.store.set(AppSettings.autoLabelsEnabled, false)
        f.center.start()
        await eventually { !f.center.isOn }
        #expect(f.center.title(for: row, labels: labels) == nil)
    }

    @Test func categoryRulesSendMarketingToOtherAtTheLowestLevel() async throws {
        let f = F(writes: false)
        let settings = AutoLabelSettingsModel(environment: f.env)
        await settings.setPlacement(.other, for: "Marketing")
        #expect(settings.placement("Marketing") == .other && settings.errorMessage == nil)
        let written = f.rules.allRules.filter { $0.kind == .matcher && $0.value == "category:marketing" }
        #expect(written.count == 2 && written.allSatisfy { $0.effect == .neverImportant }, "one rule per account")
        await f.center.classifyRecent()
        let row = try #require(try await f.inbox().first { f.center.category(of: $0.id) == "Marketing" })
        let explanation = try await f.rules.explain(row.id)
        #expect(!explanation.isImportant && explanation.reason == "Auto label Marketing goes to Other")
        let sender = try #require(row.participants.first { !$0.isMe }?.email)
        _ = try await f.rules.apply(ImportanceChange(kind: .alwaysSender, account: F.work, value: sender))
        #expect(try await f.rules.explain(row.id).isImportant)
        await settings.setPlacement(.leave, for: "Marketing")
        #expect(f.rules.allRules.allSatisfy { $0.kind != .matcher })
    }

    @Test func gmailLabelsGoOnlyThroughTheUndoableLabelPath() async throws {
        let f = F(writes: true)
        await f.center.classifyRecent()
        #expect(f.recorder.calls.contains("createLabel"), "the label is created on first use")
        let names = Set((await f.labels()).map(\.name))
        #expect(names.contains("OpenHuman/Marketing") && names.contains("OpenHuman/Waiting"))
        let ours = await f.ourLabelIDs()
        let labelled = try await f.inbox().filter { !Set($0.userLabelIDs).isDisjoint(with: ours) }
        #expect(!labelled.isEmpty)
        #expect(labelled.allSatisfy { Set($0.userLabelIDs).intersection(ours).count == 1 }, "one auto label per thread")
        #expect(!f.center.writeTokens.isEmpty)
        for token in f.center.writeTokens.reversed() { _ = try await f.recorder.undo(token) }
        #expect(try await f.inbox().allSatisfy { Set($0.userLabelIDs).isDisjoint(with: ours) })
    }

    @Test func theSwitchOffOrFakeDataKeepsLabelsOnThisMac() async throws {
        let off = F(writes: true)
        try await off.store.set(AppSettings.autoLabelsApplyToGmail, false)
        await off.center.classifyRecent()
        #expect(off.recorder.calls.isEmpty, "\u{201C}Also apply as Gmail labels\u{201D} off: nothing is written")
        #expect(try await off.index.entries(account: F.work).contains { $0.category == "Marketing" })
        let fake = F(writes: nil)
        #expect(!fake.center.canChangeGmail && !fake.center.writesToGmail)
        await fake.center.classifyRecent()
        #expect(fake.recorder.calls.isEmpty)
    }

    @Test func aLiveAccountWritesAutoLabelsToGmail() async throws {
        let live = F(writes: nil, isLiveAccount: true)
        #expect(live.center.canChangeGmail)
        await live.center.classifyRecent()
        #expect(live.recorder.calls.contains("createLabel"))
        let ours = await live.ourLabelIDs()
        #expect(try await live.inbox().contains { !Set($0.userLabelIDs).isDisjoint(with: ours) })
    }

    @Test func labelsWrittenOnOneMacAreReadBackWithoutTheModel() async throws {
        let first = F(writes: true)
        await first.center.classifyRecent()
        #expect(first.center.modelCalls > 0)
        let asked = ClassifierLog()
        let second = F(writes: true, sharing: first.store, verdict: { input in
            asked.add(input.threadKey)
            return .news
        })
        await second.center.classifyRecent()
        let ours = await second.ourLabelIDs()
        for row in try await second.inbox() where !Set(row.userLabelIDs).isDisjoint(with: ours) {
            #expect(!asked.all.contains(AIThreadLoader.threadKey(row.id)), "a labelled conversation is read back")
        }
        let entries = try await second.index.entries(account: F.work)
        #expect(entries.contains { $0.source == .gmailLabel && $0.category == "Marketing" })
        #expect(second.center.modelCalls == asked.all.count)
        #expect(!second.recorder.calls.contains("createLabel") && !second.recorder.calls.contains("apply"))
    }

    @Test func resetTakesOurLabelsOffAsOneUndoEntryAndKeepsTheLabels() async throws {
        let f = F(writes: true)
        await f.center.classifyRecent()
        let ours = await f.ourLabelIDs()
        #expect(!ours.isEmpty)
        await f.center.reset()
        #expect(try await f.inbox().allSatisfy { Set($0.userLabelIDs).isDisjoint(with: ours) })
        #expect(await f.ourLabelIDs() == ours, "the label objects are never deleted")
        #expect(try await f.index.accountIDs().isEmpty)
        let undo = try #require(f.env.undo)
        #expect(undo.canUndo)
        await undo.undoLast()
        #expect(try await f.inbox().contains { !Set($0.userLabelIDs).isDisjoint(with: ours) })
    }
}
