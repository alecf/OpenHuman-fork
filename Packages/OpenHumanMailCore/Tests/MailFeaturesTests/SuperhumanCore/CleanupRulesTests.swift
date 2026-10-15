import Foundation
import MailFakes
import MailModel
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct CleanupRulesTests {
    @Test func targetsAreNormalisedAndBadOnesRefused() {
        #expect(CleanupRulesModel.normalizedTarget("  Dana@Example.COM ") == "dana@example.com")
        #expect(CleanupRulesModel.normalizedTarget("Dana Q <dana@example.com>") == "dana@example.com")
        #expect(CleanupRulesModel.normalizedTarget("@Shop.example") == "@shop.example")
        #expect(CleanupRulesModel.normalizedTarget("shop.example") == "@shop.example")
        for bad in ["", "   ", "dana", "dana@", "a@b@c.example", "dana@nodot", "two words@x.example", "a@-x.example",
                    "a@x..example", "x.example,y.example"] {
            #expect(CleanupRulesModel.normalizedTarget(bad) == nil, "\(bad)")
        }
    }

    private func model(_ store: FakeMailStore) async -> CleanupRulesModel {
        let model = CleanupRulesModel(settings: store)
        model.start()
        return model
    }

    @Test func addChangeAndRemoveWriteTheRowTheSuggestionReads() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow))
        let model = await model(store)
        #expect(model.entries.isEmpty)
        #expect(await model.add("Shop.example", choice: .never))
        #expect(await model.add("dana@shop.example", choice: .always))
        #expect(try await store.get(AppSettings.archiveSuggestionOverrides)
                == ["@shop.example": "never", "dana@shop.example": "always"])
        await eventually { model.entries.count == 2 }
        #expect(model.entries.map(\.target) == ["dana@shop.example", "@shop.example"], "senders before domains")
        #expect(model.entries.map(\.isDomain) == [false, true])

        await model.set("@shop.example", .always)
        #expect(try await store.get(AppSettings.archiveSuggestionOverrides)["@shop.example"] == "always")
        await model.remove("dana@shop.example")
        #expect(try await store.get(AppSettings.archiveSuggestionOverrides) == ["@shop.example": "always"])
    }

    @Test func aLateInitialEmissionNeverLosesAnEarlierAdd() async throws {
        let port = LateSettingsPort()
        let model = CleanupRulesModel(settings: port)
        model.start()
        #expect(await model.add("a@shop.example", choice: .always))
        port.deliverInitialSnapshot()
        await eventually { model.overrides.value.isEmpty }
        #expect(await model.add("b@shop.example", choice: .never))
        let stored = try await port.get(AppSettings.archiveSuggestionOverrides)
        #expect(stored == ["a@shop.example": "always", "b@shop.example": "never"])
    }

    @Test func aBadTargetStoresNothingAndSaysWhy() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow))
        let model = await model(store)
        #expect(await model.add("not an address", choice: .never) == false)
        #expect(model.addError?.contains("dana@example.com") == true)
        #expect(try await store.get(AppSettings.archiveSuggestionOverrides).isEmpty)
        #expect(await model.add("ok@shop.example", choice: .never))
        #expect(model.addError == nil)
    }

    @Test func aValueThatIsNotAChoiceIsKeptButNotListed() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow))
        try await store.set(AppSettings.archiveSuggestionOverrides, ["@odd.example": "maybe", "x@y.example": "never"])
        let model = await model(store)
        await eventually { model.overrides.value.count == 2 }
        #expect(model.entries.map(\.target) == ["x@y.example"])
        await model.remove("x@y.example")
        #expect(try await store.get(AppSettings.archiveSuggestionOverrides) == ["@odd.example": "maybe"])
    }

    @Test func aRuleAddedHereIsAppliedByTheSuggestionRules() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow))
        let model = await model(store)
        _ = await model.add("friend@else.example", choice: .always)
        _ = await model.add("@news.example", choice: .never)
        let raw = try await store.get(AppSettings.archiveSuggestionOverrides)
        let rules = ArchiveSuggestionRules(overrides: raw.compactMapValues(ArchiveSuggestionOverride.init(rawValue:)))
        var written = ArchiveSuggestionFacts(sender: "friend@else.example")
        written.authorWroteToSender = true
        #expect(rules.decide(written) == .include, "Always beats \"the user wrote to them\"")
        #expect(rules.decide(ArchiveSuggestionFacts(sender: "any@news.example")) == .exclude(.neverRule))
        var spam = ArchiveSuggestionFacts(sender: "friend@else.example")
        spam.isSpam = true
        #expect(rules.decide(spam) == .exclude(.spam), "Gmail spam still wins")
    }

    @Test func theSettingsModelCarriesTheEditor() async {
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow))
        let env = AppEnvironment(data: store, commands: store, accounts: store, settings: store, isFake: true)
        let settings = InboxAutomationSettingsModel(environment: env)
        settings.start()
        _ = await settings.cleanupRules.add("a@b.example", choice: .never)
        await eventually { settings.cleanupRules.entries.count == 1 }
    }
}


final class LateSettingsPort: SettingsPort, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]

    func observe<V>(_ key: AppSettingKey<V>) -> AsyncStream<V> {
        let (stream, continuation) = AsyncStream<V>.makeStream()
        let snapshot = lock.withLock { stored[key.name] }
        let initial = snapshot.flatMap { try? JSONDecoder().decode(V.self, from: $0) } ?? key.defaultValue
        lock.withLock { releaseInitial = { continuation.yield(initial) } }
        return stream
    }
    private var releaseInitial: (() -> Void)?
    func deliverInitialSnapshot() { lock.withLock { releaseInitial }?() }

    func get<V>(_ key: AppSettingKey<V>) async throws -> V {
        let data = lock.withLock { stored[key.name] }
        return data.flatMap { try? JSONDecoder().decode(V.self, from: $0) } ?? key.defaultValue
    }

    func set<V>(_ key: AppSettingKey<V>, _ value: V) async throws {
        let data = try JSONEncoder().encode(value)
        lock.withLock { stored[key.name] = data }
    }
}
