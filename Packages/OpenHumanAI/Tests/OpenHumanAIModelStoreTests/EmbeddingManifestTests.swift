import Foundation
import Testing

@testable import OpenHumanAIModelStore

private let vocabularyLines = [
    "[PAD]", "[UNK]", "[CLS]", "[SEP]", "the", "offsite", "off", "##site", "invoice", "##s", "un", "##aff", "##able",
    "cafe", "!", ",", ".", "'", "s", "we", "move", "re", "##treat", "日", "本", "-", "write", "up", "naive",
]
private let vocabulary = Dictionary(uniqueKeysWithValues: vocabularyLines.enumerated().map { ($1, Int32($0)) })

private func tokenizer() throws -> WordPieceTokenizer { try WordPieceTokenizer(vocabulary: vocabulary) }

@Suite struct WordPieceTests {
    @Test func greedyLongestMatchWithContinuations() throws {
        let t = try tokenizer()
        #expect(t.tokenize("offsite") == ["offsite"])
        #expect(t.tokenize("invoices") == ["invoice", "##s"])
        #expect(t.tokenize("unaffable") == ["un", "##aff", "##able"])
        #expect(t.tokenize("retreat") == ["re", "##treat"])
        #expect(t.tokenize("zzz") == ["[UNK]"])
    }

    @Test func basicTokenizationLowercasesStripsAccentsAndSplitsPunctuation() throws {
        let t = try tokenizer()
        #expect(t.tokenize("We MOVE the Offsite!") == ["we", "move", "the", "offsite", "!"])
        #expect(t.tokenize("Café, naïve.") == ["cafe", ",", "naive", "."])
        #expect(t.tokenize("write-up") == ["write", "-", "up"])
        #expect(t.tokenize("we're") == ["we", "'", "re"])
        #expect(t.tokenize("日本") == ["日", "本"])
        #expect(t.tokenize("  the\t\nthe\u{0007}  ") == ["the", "the"])
        #expect(t.tokenize("") == [])
    }

    @Test func wordsLongerThanTheLimitAreUnknown() throws {
        let t = try tokenizer()
        #expect(t.tokenize(String(repeating: "a", count: WordPieceTokenizer.maxCharactersPerWord + 1)) == ["[UNK]"])
    }

    @Test func encodingAddsSpecialTokensTruncatesAndPads() throws {
        let t = try tokenizer()
        let encoding = t.encode("the offsite invoices", maxLength: 16)
        #expect(encoding.tokens == ["[CLS]", "the", "offsite", "invoice", "##s", "[SEP]"])
        #expect(encoding.ids == [2, 4, 5, 8, 9, 3])
        #expect(encoding.attentionMask == [1, 1, 1, 1, 1, 1])
        #expect(t.count("the offsite invoices") == 6)

        let cut = t.encode("the offsite invoices", maxLength: 4)
        #expect(cut.tokens == ["[CLS]", "the", "offsite", "[SEP]"])

        let padded = t.encode("the", maxLength: 8, padTo: 6)
        #expect(padded.ids == [2, 4, 3, 0, 0, 0])
        #expect(padded.attentionMask == [1, 1, 1, 0, 0, 0])
    }

    @Test func aVocabularyFileLoadsLineNumbersAsIDs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(vocabularyLines.joined(separator: "\r\n").utf8).write(to: url)
        let t = try WordPieceTokenizer(vocabularyFile: url, settings: .init(vocabFile: "vocab.txt"))
        #expect(t.vocabulary["offsite"] == 5)
        #expect(t.vocabulary["[SEP]"] == 3)
        #expect(t.tokenize("Offsite") == ["offsite"])
    }

    @Test func specialTokensMustExist() {
        #expect(throws: WordPieceTokenizer.TokenizerError.missingSpecialToken("[CLS]")) {
            _ = try WordPieceTokenizer(vocabulary: ["[PAD]": 0, "[UNK]": 1, "[SEP]": 2])
        }
        #expect(throws: WordPieceTokenizer.TokenizerError.emptyVocabulary) { _ = try WordPieceTokenizer(vocabulary: [:]) }
    }
}

@Suite struct EmbeddingManifestTests {
    private func manifest(files: [String] = ["model.mlmodelc/coremldata.bin", "vocab.txt"], format: ModelManifest.Format = .coreml,
                          modelFile: String = "model.mlmodelc", vocab: String = "vocab.txt",
                          maxSequenceLength: Int = 512) -> EmbeddingModelManifest {
        let list = files.map {
            ModelManifest.File(path: $0, url: URL(string: "https://models.example.test/e/\($0)")!, sizeBytes: 10,
                               sha256: String(repeating: "a", count: 64))
        }
        let model = ModelManifest(id: "test-embedding", displayName: "Test embedding", sourceURL: URL(string: "https://models.example.test/e")!,
                                  revision: "0123abcd", files: list, license: "test-license", format: format)
        return EmbeddingModelManifest(model: model, modelFile: modelFile, tokenizer: .init(vocabFile: vocab),
                                      output: "last_hidden_state", pooling: .cls, maxSequenceLength: maxSequenceLength,
                                      dimension: 384, queryPrefix: "query: ")
    }

    @Test func aCompleteManifestValidates() throws {
        try manifest().validate()
        let decoded = try JSONDecoder().decode(EmbeddingModelManifest.self, from: JSONEncoder().encode(manifest()))
        #expect(decoded == manifest())
    }

    @Test func missingFilesWrongFormatAndBadNumbersAreRejected() {
        #expect(throws: ModelStoreError.self) { try manifest(format: .mlx).validate() }
        #expect(throws: ModelStoreError.self) { try manifest(modelFile: "other.mlmodelc").validate() }
        #expect(throws: ModelStoreError.self) { try manifest(vocab: "missing.txt").validate() }
        #expect(throws: ModelStoreError.self) { try manifest(maxSequenceLength: 2).validate() }
        #expect(throws: ModelStoreError.self) { try manifest(files: ["../model.mlmodelc", "vocab.txt"], modelFile: "../model.mlmodelc").validate() }
    }

    @Test func theModelDownloadsThroughTheModelStoreWithHashes() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make(files: ["model.mlmodelc/coremldata.bin": "weights", "vocab.txt": "[PAD]\n[UNK]\n[CLS]\n[SEP]\n"])
        let model = ModelManifest(id: "test-embedding", displayName: "Test embedding",
                                  sourceURL: fixture.manifest.sourceURL, revision: fixture.manifest.revision,
                                  files: fixture.manifest.files, license: "test-license", format: .coreml)
        let embedding = EmbeddingModelManifest(model: model, modelFile: "model.mlmodelc", tokenizer: .init(vocabFile: "vocab.txt"),
                                               output: "embeddings", pooling: .none, maxSequenceLength: 128)
        try embedding.validate()
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 })
        let final = await finalState(await store.download(model, confirmedSizeBytes: model.totalBytes))
        guard case .ready(let directory) = final else {
            Issue.record("download did not finish: \(final)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("vocab.txt").path))
        #expect(await store.verifyInstalled(model))
        let other = makeRoot()
        defer { try? FileManager.default.removeItem(at: other) }
        let refused = await finalState(await ModelStore(rootDirectory: other, transport: fixture.transport,
                                                        freeSpace: { _ in 100 << 30 })
            .download(model, confirmedSizeBytes: model.totalBytes - 1))
        if case .failed(.sizeNotConfirmed) = refused {} else { Issue.record("expected sizeNotConfirmed, got \(refused)") }
    }
}
