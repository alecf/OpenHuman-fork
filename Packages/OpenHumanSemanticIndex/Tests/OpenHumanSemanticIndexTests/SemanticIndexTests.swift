import Foundation
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import OpenHumanSemanticIndex
import OpenHumanSemanticIndexTesting
import Testing
@testable import OpenHumanSemanticIndex

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

private func randomUnit(_ dimension: Int, _ rng: inout SeededGenerator) -> [Float] {
    EmbeddingMath.normalized((0..<dimension).map { _ in Float.random(in: -1...1, using: &rng) })
}

private func space(dimension: Int = 64) -> EmbeddingSpace {
    EmbeddingSpace(providerID: "fake.embedding", modelVersion: "test", dimension: dimension, maxInputTokens: nil)
}

private func entry(_ mid: Int64, account: Int64 = 1, thread: Int64? = nil, date: Date = Date(timeIntervalSince1970: 1_790_000_000))
    -> SemanticIndex.Entry {
    SemanticIndex.Entry(mid: mid, account: account, thread: thread ?? mid, gmailID: "g\(mid)", internalDate: date, source: 2,
                        digest: Data([UInt8(mid & 0xFF)]))
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ohsemantic-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(SemanticIndex.folderName, isDirectory: true)
}

@Suite("Semantic index")
struct SemanticIndexTests {
    @Test func quantizationRoundTripKeepsDirection() {
        var rng = SeededGenerator(state: 7)
        for _ in 0..<50 {
            let vector = randomUnit(384, &rng)
            let bytes = Int8Quantizer.encode(vector, dimension: 384)
            #expect(bytes.count == 400)
            let decoded = bytes.withUnsafeBytes { Int8Quantizer.decode($0.baseAddress!, dimension: 384) }
            #expect(EmbeddingMath.dot(EmbeddingMath.normalized(decoded), vector) > 0.995)
        }
    }

    @Test func scanAgreesWithAnExactReference() async throws {
        var rng = SeededGenerator(state: 42)
        let index = try SemanticIndex(location: .inMemory)
        try await index.activate(space(), probes: [])
        var vectors: [Int64: [Float]] = [:]
        for mid in Int64(1)...400 { vectors[mid] = randomUnit(64, &rng) }
        try await index.upsert(vectors.map { (entry: entry($0.key), vector: $0.value) })
        let query = randomUnit(64, &rng)
        let exact = vectors.sorted { EmbeddingMath.dot($0.value, query) > EmbeddingMath.dot($1.value, query) }.prefix(10).map(\.key)
        let hits = await index.search(query, filter: .init(limit: 10)).map(\.mid)
        #expect(hits.first == exact.first)
        #expect(Set(hits).intersection(exact).count >= 8)
    }

    @Test func filtersAndThePerThreadCap() async throws {
        let index = try SemanticIndex(location: .inMemory)
        try await index.activate(space(dimension: 8), probes: [])
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let same: [Float] = EmbeddingMath.normalized([1, 0, 0, 0, 0, 0, 0, 0] as [Float])
        try await index.upsert([
            (entry(1, account: 1, thread: 10, date: base), same), (entry(2, account: 1, thread: 10, date: base), same),
            (entry(3, account: 1, thread: 10, date: base), same), (entry(4, account: 1, thread: 10, date: base), same),
            (entry(5, account: 2, thread: 20, date: base.addingTimeInterval(-10 * day)), same),
        ])
        #expect(await index.search(same, filter: .init()).count == 4)
        #expect(await index.search(same, filter: .init(accounts: [2])).map(\.mid) == [5])
        #expect(await index.search(same, filter: .init(after: base.addingTimeInterval(-day))).allSatisfy { $0.thread == 10 })
        #expect(await index.search(same, filter: .init(before: base)).map(\.mid) == [5])
        #expect(await index.search(same, filter: .init(allowList: [2, 5])).map(\.mid).sorted() == [2, 5])
        #expect(await index.search(same, filter: .init(threshold: 1.5)).isEmpty)
    }

    @Test func freedSlotsAreReused() async throws {
        let index = try SemanticIndex(location: .inMemory)
        try await index.activate(space(dimension: 8), probes: [])
        let v: [Float] = EmbeddingMath.normalized([1, 1, 0, 0, 0, 0, 0, 0] as [Float])
        try await index.upsert([(entry(1), v), (entry(2), v), (entry(3), v)])
        try await index.remove(mids: [2])
        #expect(await index.count == 2)
        #expect(await index.vector(mid: 2) == nil)
        try await index.upsert([(entry(4), v)])
        #expect(await index.count == 3)
        #expect(await index.mids() == [1, 3, 4])
    }

    @Test func persistsReopensAndRecoversFromDamage() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var rng = SeededGenerator(state: 3)
        let v = randomUnit(64, &rng)
        do {
            let index = try SemanticIndex(location: .directory(folder))
            try await index.activate(space(), probes: [])
            try await index.upsert([(entry(1), v), (entry(2), randomUnit(64, &rng))])
            await index.close()
        }
        let reopened = try SemanticIndex(location: .directory(folder))
        #expect(reopened.openedAfterCleanShutdown)
        #expect(await reopened.count == 2)
        #expect(await reopened.search(v, filter: .init(limit: 1)).map(\.mid) == [1])
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        try await reopened.destroy()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: folder.appendingPathComponent(SemanticIndex.databaseName))
        let recovered = try SemanticIndex(location: .directory(folder))
        #expect(await recovered.count == 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.hasPrefix("semantic.damaged-") })
    }

    @Test func crcCheckFindsAFlippedByteAfterACrash() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var rng = SeededGenerator(state: 5)
        let s = space()
        do {
            let index = try SemanticIndex(location: .directory(folder))
            try await index.activate(s, probes: [])
            try await index.upsert([(entry(1), randomUnit(64, &rng)), (entry(2), randomUnit(64, &rng))])
        }
        let file = folder.appendingPathComponent("space-\(s.id)").appendingPathComponent("vectors.i8")
        let handle = try FileHandle(forUpdating: file)
        try handle.seek(toOffset: UInt64(MappedSlotFile.headerSize + 3))
        try handle.write(contentsOf: Data([0x55, 0xAA, 0x55, 0xAA]))
        try handle.close()
        let reopened = try SemanticIndex(location: .directory(folder))
        #expect(!reopened.openedAfterCleanShutdown)
        let damaged = try await reopened.verifyRecentSlots(since: .distantPast)
        #expect(damaged.count == 1)
        #expect(await reopened.count == 1)
    }

    @Test func removingAnAccountForgetsItsVectors() async throws {
        let index = try SemanticIndex(location: .inMemory)
        try await index.activate(space(dimension: 8), probes: [])
        let v: [Float] = EmbeddingMath.normalized([0, 1, 0, 0, 0, 0, 0, 0] as [Float])
        try await index.upsert([(entry(1, account: 1), v), (entry(2, account: 2), v)])
        try await index.addPending([(mid: 9, account: 2)])
        try await index.removeAccount(2)
        #expect(await index.mids() == [1])
        #expect(try await index.pendingByAccount()[2] == nil)
        #expect(await index.search(v, filter: .init()).map(\.account) == [1])
    }

    @Test func pacingKeepsTheDutyShare() {
        #expect(SemanticIndexer.rest(afterBusy: 1, duty: 0.25) == 3)
        #expect(SemanticIndexer.rest(afterBusy: 2, duty: 0.5) == 2)
        #expect(SemanticIndexer.rest(afterBusy: 1, duty: 1) == 0)
        #expect(SemanticIndexer.rest(afterBusy: 1, duty: 0) == 19)
    }
}

@Suite("Semantic indexer")
struct SemanticIndexerTests {
    private struct Rig {
        let source = FakeSemanticSource()
        let provider = FakeEmbeddingProvider(dimension: 64)
        let clock = TestClock()
        let index: SemanticIndex
        let indexer: SemanticIndexer

        init() throws {
            index = try SemanticIndex(location: .inMemory)
            indexer = SemanticIndexer(index: index, source: source, provider: provider, gate: OpenIndexingGate(duty: 1),
                                      clock: clock)
        }

        func search(_ text: String) async throws -> [Int64] {
            await index.search(try await provider.embed(text, role: .query), filter: .init(threshold: 0.05)).map(\.mid)
        }
    }

    @Test func embedsByMeaningAndSkipsDraftsAndSpam() async throws {
        let rig = try Rig()
        let old = rig.clock.now.addingTimeInterval(-30 * 86_400)
        let offsite = rig.source.add(subject: "Offsite dates", fromName: "Dana Ruiz", body: "Can we move the offsite to May?", date: old)
        let invoice = rig.source.add(subject: "Invoice 4471", body: "Payment due Friday", date: old)
        let draft = rig.source.add(subject: "Offsite draft", body: "offsite", date: old, isDraft: true)
        let spam = rig.source.add(subject: "Offsite deals", body: "offsite offsite", date: old, inSpam: true)
        try await rig.indexer.runRound()
        #expect(await rig.index.mids() == [offsite, invoice])
        #expect(try await rig.search("moving our team retreat").first == offsite)
        #expect(await rig.index.entry(mid: draft) == nil)
        #expect(await rig.index.entry(mid: spam) == nil)
        let texts = rig.provider.embeddedTexts
        try await rig.indexer.reconcile()
        rig.source.reuseRowid(invoice, gmailID: "g-invoice")
        try await rig.indexer.reconcile()
        try await rig.indexer.runRound()
        #expect(await rig.index.entry(mid: invoice)?.gmailID == "g-invoice")
        #expect(rig.provider.embeddedTexts == texts + 1)
    }

    @Test func youngMailFromTheSnippetThenTheBody() async throws {
        let rig = try Rig()
        let young = rig.source.add(subject: "Lunch", snippet: "Sushi at noon?", date: rig.clock.now.addingTimeInterval(-3_600))
        let old = rig.source.add(subject: "Lease renewal", snippet: "Two-year term", date: rig.clock.now.addingTimeInterval(-90 * 86_400))
        let failed = rig.source.add(subject: "Receipt", snippet: "Order confirmation", date: rig.clock.now.addingTimeInterval(-90 * 86_400))
        rig.source.failBody(failed)
        try await rig.indexer.runRound()
        #expect(await rig.index.entry(mid: young)?.source == 1)
        #expect(await rig.index.entry(mid: old) == nil)
        #expect(await rig.index.entry(mid: failed)?.source == 1)
        #expect(Set(try await rig.index.pendingByAccount()[1] ?? []) == [young, old])
        rig.source.storeBody(young, "Want to grab sushi at noon tomorrow?")
        rig.clock.advance(by: .seconds(61))
        try await rig.indexer.runRound()
        #expect(await rig.index.entry(mid: young)?.source == 2)
        #expect(await rig.index.entry(mid: old) == nil)
        rig.source.setBodyDownload(.off)
        rig.clock.advance(by: .seconds(61))
        try await rig.indexer.runRound()
        #expect(await rig.index.entry(mid: old)?.source == 1)
        #expect(try await rig.index.pendingByAccount().isEmpty)
    }

    @Test func reconciliationFreesDeletedAndReusedRows() async throws {
        let rig = try Rig()
        let date = rig.clock.now.addingTimeInterval(-86_400 * 10)
        let kept = rig.source.add(subject: "Postmortem", body: "Incident review", date: date)
        let deleted = rig.source.add(subject: "Field trip", body: "Permission slip", date: date)
        try await rig.indexer.runRound()
        rig.source.delete(deleted)
        try await rig.indexer.reconcile()
        #expect(await rig.index.mids() == [kept])
    }

    @Test func aNewStoreEpochRebuilds() async throws {
        let rig = try Rig()
        rig.source.add(subject: "Standing desk", body: "Order shipped", date: rig.clock.now.addingTimeInterval(-86_400 * 5))
        try await rig.indexer.runRound()
        #expect(await rig.index.count == 1)
        rig.source.bumpEpoch("epoch-2")
        try await rig.indexer.prepare()
        #expect(await rig.index.count == 0)
        #expect(try await rig.index.storeEpoch() == "epoch-2")
        #expect(try await rig.index.watermark() == 0)
    }

    @Test func aFailingModelCountsAndMovesOn() async throws {
        let rig = try Rig()
        rig.source.add(subject: "Contract", body: "Indemnity clause", date: rig.clock.now.addingTimeInterval(-86_400 * 5))
        try await rig.indexer.prepare()
        rig.provider.failNext()
        try await rig.indexer.runRound()
        #expect(await rig.index.count == 0)
        #expect(try await rig.index.failedCount() == 1)
        #expect(try await rig.index.watermark() > 0)
    }

    @Test func progressReachesSubscribers() async throws {
        let rig = try Rig()
        rig.source.add(subject: "Talk accepted", body: "Conference", date: rig.clock.now.addingTimeInterval(-86_400 * 5))
        var updates = rig.indexer.progress.updates().makeAsyncIterator()
        _ = await updates.next()
        try await rig.indexer.runRound()
        let latest = rig.indexer.progress.latest
        #expect(latest.embedded == 1 && latest.eligible == 1)
        #expect(latest.phase == .indexing)
    }
}
