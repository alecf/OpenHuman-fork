import Foundation
import Synchronization
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

private let summaryLine = PromptName.summarizeLine.rawValue

@Suite struct PromptLibraryProviderTests {
    @Test func anOverrideReplacesTheBodyKeepsIdAndVersionAndChangesTheDigest() throws {
        let provider = PromptLibraryProvider(bundled: .standard)
        let bundled = try provider.current.system(.summarizeLine, values: ["nonce": "N", "languageRule": "L"])
        #expect(bundled.overrideRevision == nil && bundled.overrideDigest == nil)

        provider.setOverride(PromptOverride(revision: 2, baseVersion: 3, body: "Say it in one line."), for: summaryLine)
        let mine = try provider.current.system(.summarizeLine, values: ["nonce": "N", "languageRule": "L"])
        #expect(mine.id == bundled.id)
        #expect(mine.text.hasSuffix("Say it in one line."))
        #expect(mine.digest != bundled.digest)
        #expect(mine.overrideRevision == 2 && mine.overrideDigest == Digest.sha256Hex("Say it in one line."))
        #expect(try provider.current.template(named: summaryLine).identity
                == "summarize.line@3+r2 (\(Digest.sha256Hex("Say it in one line.").prefix(8)))")

        provider.setOverride(nil, for: summaryLine)
        #expect(try provider.current.digest(.summarizeLine) == bundled.digest)
        #expect(try provider.current.template(named: summaryLine).identity == "summarize.line@3")
    }

    @Test func theBundledLibraryIsNeverChanged() throws {
        let provider = PromptLibraryProvider(bundled: try PromptLibrary.loadBundled())
        provider.setOverrides([summaryLine: PromptOverride(revision: 1, baseVersion: 3, body: "x")])
        let shipped = try PromptLibrary.loadBundled()
        #expect(provider.bundled.templates == shipped.templates)
        #expect(PromptLibrary.standard.templates == shipped.templates)
    }

    @Test func aPreambleOverrideIsReportedOnEveryRenderedPrompt() throws {
        let provider = PromptLibraryProvider(bundled: .standard, overrides: [
            PromptLibrary.preambleName: PromptOverride(revision: 1, baseVersion: 1, body: "Fence: {{nonce}}. {{languageRule}}"),
        ])
        let rendered = try provider.current.system(.replyOptions, values: ["nonce": "N1", "languageRule": "L"])
        #expect(rendered.preambleOverridden && rendered.overrideRevision == nil)
        #expect(rendered.text.hasPrefix("Fence: N1. L"))
    }

    @Test func aDraftAppliesOnlyInsideItsTask() async throws {
        let provider = PromptLibraryProvider(bundled: .standard)
        let bundledDigest = try provider.current.digest(.summarizeLine)
        let inside = try await PromptLibraryProvider.withDrafts([summaryLine: "Draft line."]) {
            let template = try provider.current.template(named: summaryLine)
            #expect(template.override?.revision == 0)
            #expect(template.identity.hasPrefix("summarize.line@3+draft"))
            let child = await Task { (try? provider.current.template(named: summaryLine).body) ?? "" }.value
            #expect(child == "Draft line.")
            return try provider.current.digest(.summarizeLine)
        }
        #expect(inside != bundledDigest)
        #expect(try provider.current.digest(.summarizeLine) == bundledDigest)
        #expect(provider.overrides.isEmpty)
    }

    @Test func theLanguageRuleComesFromItsPromptFiles() throws {
        let provider = PromptLibraryProvider(bundled: .standard, overrides: [
            PromptLibrary.languageFixedName: PromptOverride(revision: 1, baseVersion: 1, body: "Answer in {{language}} only."),
        ])
        #expect(provider.current.languageRule(.fixed("German")) == "Answer in German only.")
        #expect(PromptLibrary.standard.languageRule(.fixed("German")) == "Write in German.")
        #expect(PromptLibrary.standard.languageRule(.fixed("  ")) == PromptLibrary.standard.languageRule(.matchEmail))
    }

    @Test func anOverrideChangesTheNextRequestAndItsCacheKey() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text("A line.") }
        let prompts = PromptLibraryProvider(bundled: .standard)
        let cache = RecordingCache()
        let features = DefaultAIFeatures(
            registry: ProviderRegistry(providers: [provider]), settings: { AISettings() }, cache: cache,
            prompts: prompts, now: { fixedNow })
        let thread = SyntheticThreads.short()

        _ = try await features.summarizeLine(thread)
        prompts.setOverride(PromptOverride(revision: 1, baseVersion: 3, body: "Mine: one line."), for: summaryLine)
        _ = try await features.summarizeLine(thread)
        prompts.setOverride(nil, for: summaryLine)
        _ = try await features.summarizeLine(thread)

        #expect(provider.requests.count == 2)
        #expect(!provider.requests[0].system.contains("Mine: one line."))
        #expect(provider.requests[1].system.hasSuffix("Mine: one line."))
        #expect(provider.requests[1].promptID == provider.requests[0].promptID)
        let keys = cache.keys.map(\.digest)
        #expect(keys.count == 2 && keys[0] != keys[1])
    }
}

@Suite struct PromptRegistryTests {
    final class Clock: Sendable {
        let seconds = Mutex(0.0)
        var now: Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds.withLock { $0 }) }
        func tick() { seconds.withLock { $0 += 60 } }
    }

    func makeRegistry(_ clock: Clock = Clock()) -> (PromptRegistry, PromptLibraryProvider, InMemoryPromptOverrideStore) {
        let provider = PromptLibraryProvider(bundled: .standard)
        let store = InMemoryPromptOverrideStore()
        return (PromptRegistry(provider: provider, store: store, now: { clock.now }), provider, store)
    }

    @Test func savesAreNumberedRevertCopiesAndResetKeepsTheHistory() async throws {
        let clock = Clock()
        let (registry, provider, store) = makeRegistry(clock)
        let first = try await registry.save(summaryLine, body: "One.", note: "shorter")
        clock.tick()
        let second = try await registry.save(summaryLine, body: "Two.")
        #expect(first.revision == 1 && second.revision == 2 && first.baseVersion == 3)
        #expect(first.origin == .edit && first.note == "shorter" && second.createdAt > first.createdAt)
        #expect(provider.overrides[summaryLine]?.body == "Two.")

        let reverted = try await registry.revert(summaryLine, to: 1)
        #expect(reverted.revision == 3 && reverted.origin == .revert && reverted.body == "One.")
        #expect(provider.overrides[summaryLine]?.revision == 3)

        try await registry.reset(summaryLine)
        #expect(provider.overrides[summaryLine] == nil)
        #expect(try provider.current.digest(.summarizeLine) == (try PromptLibrary.standard.digest(.summarizeLine)))
        #expect(await store.activeRevisions().isEmpty)
        #expect(try await registry.history(summaryLine).map(\.revision) == [3, 2, 1])

        #expect(try await registry.save(summaryLine, body: "Four.").revision == 4)
        #expect(try await registry.revisionCounts() == [summaryLine: 4])
    }

    @Test func refusedTextsStoreNothing() async throws {
        let (registry, provider, store) = makeRegistry()
        let huge = String(repeating: "a", count: PromptCatalog.maxBodyBytes + 1)
        for (body, problem) in [("  \n", PromptProblem.empty), ("Hi {{who}}", .unknownSlot("who")),
                                ("Hi {{nonce", .unclosedSlot), (huge, .tooLarge(bytes: huge.utf8.count))] {
            await #expect(throws: PromptRegistryError.refused([problem])) {
                try await registry.save(summaryLine, body: body)
            }
        }
        await #expect(throws: PromptRegistryError.unknownPrompt("nope.prompt")) {
            try await registry.save("nope.prompt", body: "x")
        }
        #expect(await store.revisionCounts().isEmpty && provider.overrides.isEmpty)
    }

    @Test func loadPutsTheStoredVersionsInUseAndSkipsUnknownIds() async throws {
        let store = InMemoryPromptOverrideStore()
        _ = await store.addRevision(promptID: summaryLine, baseVersion: 2, body: "Old base.", origin: .edit, note: nil,
                                    at: fixedNow)
        _ = await store.addRevision(promptID: "gone.prompt", baseVersion: 1, body: "x", origin: .edit, note: nil,
                                    at: fixedNow)
        let provider = PromptLibraryProvider(bundled: .standard)
        try await PromptRegistry(provider: provider, store: store, now: { fixedNow }).load()
        #expect(Set(provider.overrides.keys) == [summaryLine])
        #expect(provider.overrides[summaryLine]?.baseVersion == 2)
        #expect(try provider.current.template(named: summaryLine).body == "Old base.")
    }

    @Test func revertingAnUnknownRevisionThrows() async throws {
        let (registry, _, _) = makeRegistry()
        await #expect(throws: PromptOverrideStoreError.unknownRevision(summaryLine, 9)) {
            try await registry.revert(summaryLine, to: 9)
        }
    }
}

@Suite struct PromptCatalogTests {
    @Test func everyBundledFileIsListedOnceAndEveryEntryHasAFile() throws {
        let library = try PromptLibrary.loadBundled()
        #expect(Set(PromptCatalog.ids) == Set(library.templates.keys))
        #expect(PromptCatalog.ids.count == Set(PromptCatalog.ids).count)
        for entry in PromptCatalog.entries {
            let template = try library.template(named: entry.id)
            #expect(template.placeholders.isSubset(of: entry.slots), "\(entry.id) uses a slot the app does not fill")
            #expect(entry.neededSlots.isSubset(of: template.placeholders), "\(entry.id) misses a needed slot")
            let check = PromptCheck.of(template.body, for: entry)
            #expect(check.problems.isEmpty && check.warnings.allSatisfy { $0 == .injectionPolicy },
                    "\(entry.id) warns on its own text")
            if let name = entry.promptName { #expect(name.role == entry.role) }
        }
    }

    @Test func checksRefuseOnlyEmptyUnknownUnclosedAndOversizedText() throws {
        let line = try #require(PromptCatalog.entry(summaryLine))
        #expect(PromptCheck.of(String(repeating: "a", count: PromptCatalog.maxBodyBytes), for: line).canSave)
        #expect(PromptCheck.of("Use {{nonce}} and {{languageRule}}.", for: line).canSave)
        #expect(PromptCheck.of("Use {{x}} and {{y}}.", for: line).problems == [.unknownSlot("x"), .unknownSlot("y")])
    }

    @Test func warningsNeverBlock() throws {
        let labels = try #require(PromptCatalog.entry(PromptName.autoLabel.rawValue))
        let noJSON = PromptCheck.of("Pick a category.", for: labels)
        #expect(noJSON.canSave && noJSON.warnings == [.noJSONForm])
        let preamble = try #require(PromptCatalog.entry(PromptLibrary.preambleName))
        let fence = PromptCheck.of("Be careful. {{languageRule}}", for: preamble)
        #expect(fence.canSave && fence.warnings == [.injectionPolicy, .missingSlot("nonce")])
        let notes = try #require(PromptCatalog.entry(PromptName.composerNotes.rawValue))
        #expect(PromptCheck.of("Write an email.", for: notes).warnings == [.missingSlot("notes")])
    }
}

@Suite struct PromptDiffTests {
    @Test func linesAreKeptRemovedOrAdded() {
        let diff = PromptDiff.lines(from: "a\nb\nc", to: "a\nx\nc\nd")
        #expect(diff == [.init(.same, "a"), .init(.removed, "b"), .init(.added, "x"), .init(.same, "c"),
                         .init(.added, "d")])
        #expect(PromptDiff.lines(from: "same", to: "same") == [.init(.same, "same")])
    }
}
