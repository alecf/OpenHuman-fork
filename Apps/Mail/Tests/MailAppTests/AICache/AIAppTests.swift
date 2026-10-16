import Foundation
import MailFeatures
import OpenHumanAI
import OpenHumanAIAgentCLI
import OpenHumanCore
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

@Suite struct SQLiteAIResultCacheTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oh-ai-cache-\(UUID().uuidString)", isDirectory: true)
    }

    static func key(_ n: Int, thread: String? = "1.t1") -> AICacheKey {
        AICacheKey(digest: "digest-\(n)", threadKey: thread)
    }

    static let result = CachedAIResult(payload: .text("A short summary."), providerID: .appleSystem,
                                       providerName: "Apple on-device model", dataLocation: .onDevice, model: nil,
                                       createdAt: Date(timeIntervalSince1970: 1_791_000_000))

    @Test func resultsRoundTripAndSurviveARelaunch() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLiteAIResultCache.fileName)
        let cache = try SQLiteAIResultCache(url: url)
        await cache.put(Self.key(1), Self.result, ttl: nil)
        #expect(await cache.get(Self.key(1)) == Self.result)
        #expect(await cache.get(Self.key(2)) == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600, "the cache holds email-derived text: owner only")
        let reopened = try SQLiteAIResultCache(url: url)
        #expect(await reopened.get(Self.key(1))?.provenance.fromCache == true)
    }

    @Test func theCacheIsExcludedFromBackupsAndDeletesSecurely() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLiteAIResultCache.fileName)
        let cache = try SQLiteAIResultCache(url: url)
        await cache.put(Self.key(1), Self.result, ttl: nil)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true,
                "only the cache file, not the folder it shares with the mail store")
        #expect(await cache.secureDelete == 1)
    }

    @Test func expiredResultsAreGoneAndThreadsInvalidate() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let cache = try SQLiteAIResultCache(url: dir.appendingPathComponent("c.sqlite"), now: { clock.now })
        await cache.put(Self.key(1), Self.result, ttl: .seconds(24 * 3600))
        await cache.put(Self.key(2, thread: "1.t2"), Self.result, ttl: nil)
        await cache.put(Self.key(3, thread: "1.t2"), Self.result, ttl: nil)
        clock.now = clock.now.addingTimeInterval(24 * 3600 + 1)
        #expect(await cache.get(Self.key(1)) == nil, "reply options and PCC results expire after 24 h")
        #expect(await cache.get(Self.key(2)) != nil)
        await cache.invalidate(threadKey: "1.t2")
        #expect(await cache.get(Self.key(2)) == nil)
        #expect(await cache.get(Self.key(3)) == nil)
        await cache.put(Self.key(4), Self.result, ttl: nil)
        await cache.removeAll()
        #expect(await cache.count == 0)
    }

    @Test func theCacheIsBoundedOldestFirst() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let cache = try SQLiteAIResultCache(url: dir.appendingPathComponent("c.sqlite"), capacity: 3, now: { clock.now })
        for n in 1...5 {
            await cache.put(Self.key(n), Self.result, ttl: nil)
            clock.now = clock.now.addingTimeInterval(1)
        }
        #expect(await cache.count == 3)
        #expect(await cache.get(Self.key(1)) == nil)
        #expect(await cache.get(Self.key(2)) == nil)
        #expect(await cache.get(Self.key(5)) != nil)
    }

    @Test func aDamagedFileIsSetAsideAndTheCacheStartsAgain() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(SQLiteAIResultCache.fileName)
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        let cache = try SQLiteAIResultCache(url: url)
        await cache.put(Self.key(1), Self.result, ttl: nil)
        #expect(await cache.get(Self.key(1)) == Self.result)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.contains("damaged") })
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_791_000_000)
        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}

@MainActor
@Suite struct AIServicesTests {
    @Test func testsAndFakeDataGetTheFakeProviderOnly() async throws {
        let live = AIServices.aiCenter(model: .onDevice, persistent: true, environment: ["XCTestConfigurationFilePath": "x"])
        #expect(live.registry?.providers.map(\.id) == [.fake])
        let fake = AIServices.aiCenter(model: .fake, persistent: false, environment: [:])
        #expect(fake.registry?.providers.map(\.id) == [.fake])
        try fake.update { $0.draftReplies = .off }
        #expect(fake.settings.draftReplies == .off, "kept in memory (the real suite is never written by a fake run)")

        let app = CompositionRoot.makeApp(arguments: ["-UseFakeData"], environment: ["XCTestConfigurationFilePath": "x"])
        guard case .mail(let environment) = app.screen else { Issue.record("not the mail screen"); return }
        let center = try #require(environment.ai)
        #expect(center.registry?.providers.map(\.id) == [.fake])
        #expect(environment.actions.contains(.aiRewrite) && environment.actions.contains(.aiSummarize))
    }

    @Test func theWelcomeGuidesAIStepGoesThroughTheAICenter() {
        let center = AIServices.aiCenter(model: .fake, persistent: false, environment: [:])
        #expect(CompositionRoot.aiOnboarding(isFake: false, center: center, underTest: false) is AICenterOnboarding,
                "one owner of the AI settings: the guide's choice reaches the center at once")
        #expect(CompositionRoot.aiOnboarding(isFake: false, center: center, underTest: true) == nil)
    }

    @Test func theAgentCLIFactoryBuildsOnlyClaudeCodeAndCodex() {
        var settings = AISettings()
        settings.agentCLI[.agentClaude] = AgentCLISettings(binaryPathOverride: "/opt/bin/claude", model: "sonnet")
        let claude = AIServices.agentCLI(.agentClaude, settings: settings) as? AgentCLIProvider
        #expect(claude?.kind == .claude && claude?.configuration.overridePath == "/opt/bin/claude")
        #expect(claude?.configuration.model == "sonnet")
        #expect((AIServices.agentCLI(.agentCodex, settings: settings) as? AgentCLIProvider)?.kind == .codex)
        #expect(AIServices.agentCLI(.appleSystem, settings: settings) == nil)
        #expect(AIServices.agentCLI(.applePCC, settings: settings) == nil)
    }
}
