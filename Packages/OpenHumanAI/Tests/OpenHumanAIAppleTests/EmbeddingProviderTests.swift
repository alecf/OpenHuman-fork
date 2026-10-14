import Foundation
import NaturalLanguage
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIApple
@testable import OpenHumanAIModelStore

let sentenceEmbeddingIsAvailable = NLEmbedding.sentenceEmbedding(for: .english) != nil

@Suite struct SystemEmbeddingAvailabilityTests {
    @Test func reportsWhatThisMacHas() async {
        let sentence = NLSentenceEmbeddingProvider()
        let contextual = NLContextualEmbeddingProvider()
        print("apple.nl.sentence availability: \(await sentence.availability())")
        print("apple.nl.contextual availability: \(await contextual.availability())")
        #expect(sentence.dataLocation == .onDevice)
        #expect(contextual.dataLocation == .onDevice)
        #expect(EmbeddingProviders.onDeviceOnly(sentence) != nil)
        #expect(EmbeddingProviders.onDeviceOnly(contextual) != nil)
    }
}

@Suite(.enabled(if: sentenceEmbeddingIsAvailable, "needs NaturalLanguage sentence-embedding assets"))
struct SentenceEmbeddingTests {
    let provider = NLSentenceEmbeddingProvider()
    let texts = ["Can we move the offsite to the second week?", "Invoice 4471 is attached.", "The lodge is booked."]

    @Test func unitVectorsInInputOrderWithTheRuntimeDimension() async throws {
        let space = try await provider.space()
        print("apple.nl.sentence dimension: \(space.dimension)")
        #expect(space.dimension > 0)
        #expect(space.maxInputTokens == nil)
        #expect(space.isConsistent)
        let batch = try await provider.embed(texts, role: .document)
        #expect(batch.count == texts.count)
        for (index, vector) in batch.enumerated() {
            #expect(vector.count == space.dimension)
            #expect(EmbeddingMath.isUnitLength(vector))
            #expect(try await provider.embed([texts[index]], role: .document) == [vector])
        }
    }

    @Test func theProbeMatchesItselfSoTheSpaceIsStable() async throws {
        let first = try await provider.space()
        await provider.unload()
        let second = try await NLSentenceEmbeddingProvider().space()
        #expect(first.id == second.id)
        let probes = try await provider.embed(EmbeddingProbe.sentences, role: .document)
        #expect(EmbeddingProbe.matches(probes, probes))
    }
}

@Suite struct ContextualEmbeddingTests {
    @Test func unitVectorsWhenTheAssetsArePresent() async throws {
        let provider = NLContextualEmbeddingProvider()
        guard await provider.availability().isAvailable else {
            print("apple.nl.contextual: no assets on this Mac; skipped")
            return
        }
        let space = try await provider.space()
        print("apple.nl.contextual dimension: \(space.dimension), max tokens: \(space.maxInputTokens.map(String.init) ?? "-")")
        #expect(space.dimension > 0)
        let texts = ["The team retreat moves one week later.", "Order confirmation for a standing desk."]
        let batch = try await provider.embed(texts, role: .document)
        #expect(batch.count == 2)
        #expect(batch.allSatisfy { EmbeddingMath.isUnitLength($0) && $0.count == space.dimension })
        #expect(try await provider.embed([texts[1]], role: .document) == [batch[1]])
    }
}

@Suite struct CoreMLEmbeddingProviderTests {
    private func manifest() -> EmbeddingModelManifest {
        let files = ["model.mlmodelc/coremldata.bin", "vocab.txt"].map {
            ModelManifest.File(path: $0, url: URL(string: "https://models.example.test/e/\($0)")!, sizeBytes: 1_000,
                               sha256: String(repeating: "b", count: 64))
        }
        let model = ModelManifest(id: "bge-small-en", displayName: "bge-small (test manifest)",
                                  sourceURL: URL(string: "https://models.example.test/e")!, revision: "0123abcd", files: files,
                                  license: "test-license", format: .coreml)
        return EmbeddingModelManifest(model: model, modelFile: "model.mlmodelc", tokenizer: .init(vocabFile: "vocab.txt"),
                                      output: "last_hidden_state", pooling: .cls, maxSequenceLength: 512)
    }

    @Test func missingFilesAreUnavailableAndNothingIsDownloaded() async {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("embedding-empty-\(UUID().uuidString)")
        let provider = CoreMLEmbeddingProvider(manifest: manifest(), modelDirectory: empty)
        #expect(provider.id == EmbeddingProviders.bgeSmall)
        #expect(provider.dataLocation == .onDevice)
        #expect(await provider.availability() == .unavailable(reason: .modelNotDownloaded(sizeBytes: 2_000)))
        #expect(await aiError { _ = try await provider.space() } == .unavailable(.modelNotDownloaded(sizeBytes: 2_000)))
        #expect(await aiError { _ = try await provider.embed(["x"], role: .query) }
                == .unavailable(.modelNotDownloaded(sizeBytes: 2_000)))
        #expect(!FileManager.default.fileExists(atPath: empty.path))
    }

    @Test func aBrokenModelFileReportsAFailureNotACrash() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("embedding-broken-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("model.mlmodelc"), withIntermediateDirectories: true)
        try Data("not a model".utf8).write(to: folder.appendingPathComponent("model.mlmodelc/coremldata.bin"))
        try Data("[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\n".utf8).write(to: folder.appendingPathComponent("vocab.txt"))
        let provider = CoreMLEmbeddingProvider(manifest: manifest(), modelDirectory: folder)
        #expect(await provider.availability() == .available)
        #expect(await provider.countTokens("hello hello") == 4)
        let error = await aiError { _ = try await provider.embed(["hello"], role: .document) }
        #expect(error == .providerFailed("the embedding model could not be loaded"))
    }
}
