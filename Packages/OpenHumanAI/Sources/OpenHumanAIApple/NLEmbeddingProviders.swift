import Foundation
import NaturalLanguage
import OpenHumanAI

enum SystemEmbeddingVersion {
    static var osBuild: String { ProcessInfo.processInfo.operatingSystemVersionString }

    static func make(revision: Int, probes: [[Float]]) -> String {
        "\(osBuild) r\(revision) p\(EmbeddingProbe.digest(probes))"
    }
}

public actor NLSentenceEmbeddingProvider: TextEmbeddingProvider {
    public nonisolated let id: AIProviderID = EmbeddingProviders.appleSentence
    public nonisolated let displayName = "Built into macOS (sentence embedding)"
    public nonisolated let dataLocation: AIDataLocation = .onDevice
    public nonisolated let preferredBatchSize = 16

    private let language: NLLanguage
    private var embedding: NLEmbedding?
    private var cachedSpace: EmbeddingSpace?

    public init(language: NLLanguage = .english) {
        self.language = language
    }

    private func loaded() -> NLEmbedding? {
        if let embedding { return embedding }
        embedding = NLEmbedding.sentenceEmbedding(for: language)
        return embedding
    }

    public func availability() async -> AIAvailability {
        loaded() == nil ? .unavailable(reason: .modelNotReady) : .available
    }

    public func space() async throws -> EmbeddingSpace {
        if let cachedSpace { return cachedSpace }
        guard let embedding = loaded() else { throw AIError.unavailable(.modelNotReady) }
        let probes = EmbeddingProbe.sentences.map { vector($0, embedding) }
        let space = EmbeddingSpace(providerID: id, modelVersion: SystemEmbeddingVersion.make(revision: embedding.revision, probes: probes),
                                   dimension: embedding.dimension, maxInputTokens: nil)
        cachedSpace = space
        return space
    }

    public func countTokens(_ text: String) async -> Int { TokenHeuristic.count(text) }

    public func embed(_ texts: [String], role: EmbeddingRole) async throws -> [[Float]] {
        guard let embedding = loaded() else { throw AIError.unavailable(.modelNotReady) }
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            if Task.isCancelled { throw AIError.cancelled }
            vectors.append(vector(text, embedding))
        }
        return vectors
    }

    public func prewarm() async { _ = loaded() }

    public func unload() async {
        embedding = nil
    }

    private func vector(_ text: String, _ embedding: NLEmbedding) -> [Float] {
        guard let values = embedding.vector(for: text), !values.isEmpty else {
            return EmbeddingMath.normalized([Float](repeating: 0, count: max(embedding.dimension, 1)))
        }
        return EmbeddingMath.normalized(values)
    }
}

public actor NLContextualEmbeddingProvider: TextEmbeddingProvider {
    public nonisolated let id: AIProviderID = EmbeddingProviders.appleContextual
    public nonisolated let displayName = "Built into macOS (contextual embedding)"
    public nonisolated let dataLocation: AIDataLocation = .onDevice
    public nonisolated let preferredBatchSize = 8

    private let language: NLLanguage
    private var embedding: NLContextualEmbedding?
    private var isLoaded = false
    private var cachedSpace: EmbeddingSpace?

    public init(language: NLLanguage = .english) {
        self.language = language
    }

    private func model() -> NLContextualEmbedding? {
        if let embedding { return embedding }
        embedding = NLContextualEmbedding(language: language)
        return embedding
    }

    public func availability() async -> AIAvailability {
        guard let model = model() else { return .unavailable(reason: .localeNotSupported) }
        return model.hasAvailableAssets ? .available : .unavailable(reason: .modelNotReady)
    }

    public func requestAssets() async -> Bool {
        guard let model = model() else { return false }
        let result = try? await model.requestAssets()
        return result == .available
    }

    private func ready() throws -> NLContextualEmbedding {
        guard let model = model(), model.hasAvailableAssets else { throw AIError.unavailable(.modelNotReady) }
        if !isLoaded {
            do { try model.load() } catch { throw AIError.unavailable(.modelNotReady) }
            isLoaded = true
        }
        return model
    }

    public func space() async throws -> EmbeddingSpace {
        if let cachedSpace { return cachedSpace }
        let model = try ready()
        let probes = try EmbeddingProbe.sentences.map { try vector($0, model) }
        let space = EmbeddingSpace(providerID: id, modelVersion: SystemEmbeddingVersion.make(revision: model.revision, probes: probes),
                                   dimension: model.dimension,
                                   maxInputTokens: model.maximumSequenceLength > 0 ? model.maximumSequenceLength : nil)
        cachedSpace = space
        return space
    }

    public func countTokens(_ text: String) async -> Int { TokenHeuristic.count(text) }

    public func embed(_ texts: [String], role: EmbeddingRole) async throws -> [[Float]] {
        let model = try ready()
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            if Task.isCancelled { throw AIError.cancelled }
            vectors.append(try vector(text, model))
        }
        return vectors
    }

    public func prewarm() async { _ = try? ready() }

    public func unload() async {
        embedding?.unload()
        isLoaded = false
    }

    private func vector(_ text: String, _ model: NLContextualEmbedding) throws -> [Float] {
        guard !text.isEmpty else { return EmbeddingMath.normalized([Float](repeating: 0, count: max(model.dimension, 1))) }
        let result: NLContextualEmbeddingResult
        do {
            result = try model.embeddingResult(for: text, language: language)
        } catch {
            throw AIError.providerFailed("contextual embedding failed")
        }
        var tokens: [[Float]] = []
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { values, _ in
            tokens.append(values.map { Float($0) })
            return true
        }
        guard let mean = EmbeddingMath.mean(tokens) else {
            return EmbeddingMath.normalized([Float](repeating: 0, count: max(model.dimension, 1)))
        }
        return EmbeddingMath.normalized(mean)
    }
}
