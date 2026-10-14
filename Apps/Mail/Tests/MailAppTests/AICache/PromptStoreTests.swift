import Foundation
import OpenHumanAI
import Testing
@testable import OpenHumanMail

@Suite struct PromptStoreTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oh-prompts-\(UUID().uuidString)", isDirectory: true)
    }

    static let day = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func revisionsAreMonotonicRevertCopiesResetKeepsHistoryAndARelaunchReadsTheActiveOnes() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLitePromptStore.fileName)
        let store = try SQLitePromptStore(url: url)
        #expect(await store.userVersion == 1 && store.activeAtOpen.isEmpty)
        let first = try await store.addRevision(promptID: "summarize.line", baseVersion: 3, body: "One.", origin: .edit,
                                                note: "shorter", at: Self.day)
        let second = try await store.addRevision(promptID: "summarize.line", baseVersion: 3, body: "Two.", origin: .edit,
                                                 note: nil, at: Self.day.addingTimeInterval(60))
        _ = try await store.addRevision(promptID: "reply.options", baseVersion: 2, body: "Three replies.", origin: .edit,
                                        note: nil, at: Self.day)
        #expect(first.revision == 1 && second.revision == 2)
        #expect(try await store.activeRevisions()["summarize.line"]?.body == "Two.")

        try await store.setActive(promptID: "summarize.line", revision: nil, at: Self.day)
        #expect(try await store.activeRevisions()["summarize.line"] == nil)
        let third = try await store.addRevision(promptID: "summarize.line", baseVersion: 3, body: first.body,
                                                origin: .revert, note: "Reverted to r1", at: Self.day)
        #expect(third.revision == 3 && third.digest == first.digest)
        #expect(try await store.history(of: "summarize.line").map(\.revision) == [3, 2, 1])
        #expect(try await store.revisionCounts() == ["summarize.line": 3, "reply.options": 1])
        await #expect(throws: PromptOverrideStoreError.unknownRevision("summarize.line", 9)) {
            try await store.setActive(promptID: "summarize.line", revision: 9, at: Self.day)
        }

        let reopened = try SQLitePromptStore(url: url)
        #expect(reopened.activeAtOpen.mapValues(\.revision) == ["summarize.line": 3, "reply.options": 1])
        let history = try await reopened.history(of: "summarize.line")
        #expect(history.last?.note == "shorter" && history.last?.origin == .edit && history.first?.origin == .revert)
        #expect(history.last?.createdAt == Self.day && history.last?.baseVersion == 3)
    }

    @Test func theFileIsPrivateKeptInBackupsAndADamagedOneIsSetAside() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLitePromptStore.fileName)
        _ = try SQLitePromptStore(url: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
        try Data("not a database".utf8).write(to: url)
        let fresh = try SQLitePromptStore(url: url)
        #expect(try await fresh.revisionCounts().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.contains("damaged") })
    }

    @Test func aSavedVersionIsUsedAndSurvivesARelaunch() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLitePromptStore.fileName)
        let provider = PromptLibraryProvider(bundled: .standard)
        let registry = PromptRegistry(provider: provider, store: try SQLitePromptStore(url: url), now: { Self.day })
        try await registry.save("summarize.line", body: "Say it in one sentence.")
        #expect(try provider.current.template(named: "summarize.line").body == "Say it in one sentence.")

        let relaunched = PromptLibraryProvider(bundled: .standard)
        try await PromptRegistry(provider: relaunched, store: try SQLitePromptStore(url: url), now: { Self.day }).load()
        #expect(relaunched.overrides["summarize.line"]?.revision == 1)
        #expect(try relaunched.current.digest(.summarizeLine) != (try PromptLibrary.standard.digest(.summarizeLine)))
    }

    @MainActor @Test func underTestTheRegistryIsInMemory() {
        PromptServices.install(persistent: false, directory: nil)
        #expect(PromptServices.current?.store is InMemoryPromptOverrideStore)
    }
}
