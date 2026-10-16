import Foundation
import OpenHumanAI
import Testing
@testable import OpenHumanMailLive

@Suite struct AITraceStoreTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oh-traces-\(UUID().uuidString)", isDirectory: true)
    }

    static let day = Date(timeIntervalSince1970: 1_791_000_000)
    static let keep = AITraceSettings().retention

    static func trace(_ index: Int, feature: AIFeature = .rewrite, minutesAgo: Double = 0, accounts: [String] = ["account.home"],
                      text: String = "Invented draft about the offsite") -> AITraceRecord
    {
        AITraceRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            createdAt: day.addingTimeInterval(-minutesAgo * 60), feature: feature, task: .rewrite, trigger: .user,
            accountKeys: accounts, threadKey: "thread-\(index)", parentID: nil, promptID: PromptID("rewrite.instruct", version: 3),
            promptDigest: "digest", overrideRevision: 2, providerID: .appleSystem, providerName: "Apple on-device model",
            model: "model-1", modelVersion: "apple.system|1", dataLocation: .thirdParty(vendor: "Example vendor"),
            parameters: AITraceParameters(temperature: 0.4, outputLimit: 900, inputBudget: 2_000),
            systemText: "System \(AITraceRecord.nonceStandIn)", inputText: text, inputParts: [
                AITracePart(kind: "userInstruction", id: nil, characters: 12, trusted: true),
                AITracePart(kind: "draft", id: "draft", characters: text.count, trusted: false),
            ], outputText: "Raw " + text, finalText: "Shown " + text, steps: [AITraceStep(.stoppedAtOutputLimit)],
            countedInputTokens: 310, contextTokens: 4_096, usage: AIUsage(inputTokens: 300, outputTokens: 40),
            latencyMilliseconds: 150, firstTokenMilliseconds: 120, cache: .miss, outcome: .completed)
    }

    @Test func aTraceRoundTripsAndSurvivesAReopen() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLiteAITraceStore.fileName)
        let store = try SQLiteAITraceStore(url: url)
        #expect(await store.userVersion == 1)
        let original = Self.trace(1)
        try await store.append(original, retention: Self.keep, now: Self.day)
        #expect(try await store.trace(original.id) == original)

        try await store.amend(original.id, finalText: "Shown after trimming", steps: [AITraceStep(.flaggedSuspicious)])
        try await store.setRating(original.id, rating: -1)
        let reopened = try SQLiteAITraceStore(url: url)
        let loaded = try #require(try await reopened.trace(original.id))
        #expect(loaded.finalText == "Shown after trimming" && loaded.rating == -1)
        #expect(loaded.steps.map(\.kind) == [.stoppedAtOutputLimit, .flaggedSuspicious])
        #expect(loaded.leftDevice && loaded.dataLocation == .thirdParty(vendor: "Example vendor"))
    }

    @Test func retentionPrunesByAgePerFeatureAndSize() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteAITraceStore(url: dir.appendingPathComponent(SQLiteAITraceStore.fileName))
        try await store.append(Self.trace(1, minutesAgo: 60 * 24 * 31), retention: Self.keep, now: Self.day.addingTimeInterval(-60 * 60 * 24 * 31))
        try await store.append(Self.trace(2, minutesAgo: 3), retention: Self.keep, now: Self.day)
        #expect(try await store.recent(limit: 10).map(\.id) == [Self.trace(2).id], "older than 30 days is gone")

        let two = AITraceRetention(keepFor: 86_400, perFeature: 2, maxBytes: .max)
        try await store.append(Self.trace(3, minutesAgo: 2), retention: two, now: Self.day)
        try await store.append(Self.trace(4, minutesAgo: 1), retention: two, now: Self.day)
        try await store.append(Self.trace(5, feature: .summarize, minutesAgo: 5), retention: two, now: Self.day)
        #expect(try await store.recent(limit: 10).map(\.id) == [Self.trace(4).id, Self.trace(3).id, Self.trace(5).id])

        let small = AITraceRetention(keepFor: 86_400, perFeature: 500, maxBytes: Self.trace(4).textBytes * 2)
        try await store.append(Self.trace(6, minutesAgo: 0.5), retention: small, now: Self.day)
        #expect(try await store.recent(limit: 10).map(\.id) == [Self.trace(6).id, Self.trace(4).id])
    }

    @Test func signingOutForgetsOnlyThatAccountAndClearAllEmptiesTheFile() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteAITraceStore(url: dir.appendingPathComponent(SQLiteAITraceStore.fileName))
        try await store.append(Self.trace(1, minutesAgo: 3, accounts: ["account.home"]), retention: Self.keep, now: Self.day)
        try await store.append(Self.trace(2, minutesAgo: 2, accounts: ["account.work"]), retention: Self.keep, now: Self.day)
        try await store.append(Self.trace(3, minutesAgo: 1, accounts: ["account.home", "account.work"]),
                               retention: Self.keep, now: Self.day)
        try await store.forget(accountKey: "account.work")
        #expect(try await store.recent(limit: 10).map(\.id) == [Self.trace(1).id])
        try await store.delete(Self.trace(1).id)
        #expect(try await store.recent(limit: 10).isEmpty)
        try await store.append(Self.trace(4), retention: Self.keep, now: Self.day)
        try await store.deleteAll()
        #expect(try await store.recent(limit: 10).isEmpty)
    }

    @Test func queriesFilterInTheFileSoOldRatingsAndHandRequestsAreNotCrowdedOut() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteAITraceStore(url: dir.appendingPathComponent(SQLiteAITraceStore.fileName))
        var rated = Self.trace(1, minutesAgo: 120)
        rated.rating = -1
        try await store.append(rated, retention: Self.keep, now: Self.day)
        for index in 2...12 {
            var background = Self.trace(index, feature: .summarize, minutesAgo: Double(13 - index))
            background.trigger = .automatic
            try await store.append(background, retention: Self.keep, now: Self.day)
        }
        try await store.append(Self.trace(13, feature: .askInbox, minutesAgo: 30), retention: Self.keep, now: Self.day)
        #expect(!(try await store.recent(limit: 5)).contains { $0.id == rated.id })
        #expect(try await store.traces(matching: AITraceQuery(rating: .rated), limit: 5).map(\.id) == [rated.id])
        #expect(try await store.traces(matching: AITraceQuery(rating: .thumbsDown), limit: 5).map(\.id) == [rated.id])
        #expect(try await store.traces(matching: AITraceQuery(triggers: [.user]), limit: 5).map(\.id)
            == [Self.trace(13).id, rated.id])
        #expect(try await store.traces(matching: AITraceQuery(features: [.rewrite, .askInbox], triggers: [.user]), limit: 1)
            .map(\.id) == [Self.trace(13).id])
        #expect(try await store.traces(matching: AITraceQuery(triggers: [.automatic]), limit: 100).count == 11)
    }

    @Test func turningTextOffStoresNoText() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteAITraceStore(url: dir.appendingPathComponent(SQLiteAITraceStore.fileName))
        let settings = AITraceSettings(includeText: false)
        let sink = StoreTraceSink(store: store, settings: { settings }, now: { Self.day })
        await sink.record(Self.trace(1))
        let loaded = try #require(try await store.trace(Self.trace(1).id))
        #expect(loaded.systemText == nil && loaded.inputText == nil && loaded.outputText == nil && loaded.finalText == nil)
        #expect(loaded.inputParts.count == 2 && loaded.latencyMilliseconds == 150)
    }

    @Test func theFileIsPrivateAndADamagedOneIsSetAside() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLiteAITraceStore.fileName)
        _ = try SQLiteAITraceStore(url: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
        try Data("not a database".utf8).write(to: url)
        let fresh = try SQLiteAITraceStore(url: url)
        #expect(try await fresh.recent(limit: 10).isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.contains("damaged") })
    }
}
