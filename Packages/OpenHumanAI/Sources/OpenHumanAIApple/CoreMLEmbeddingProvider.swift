import CoreML
import Foundation
import OpenHumanAI
import OpenHumanAIModelStore

public actor CoreMLEmbeddingProvider: TextEmbeddingProvider {
    public nonisolated let id: AIProviderID
    public nonisolated let displayName: String
    public nonisolated let dataLocation: AIDataLocation = .onDevice
    public nonisolated let preferredBatchSize = 16

    private let manifest: EmbeddingModelManifest
    private let directory: URL
    private let computeUnits: MLComputeUnits
    private var model: MLModel?
    private var tokenizer: WordPieceTokenizer?
    private var dimension: Int?

    public init(manifest: EmbeddingModelManifest, modelDirectory: URL, computeUnits: MLComputeUnits = .all) {
        self.id = .local(manifest.model.id)
        self.displayName = manifest.model.displayName
        self.manifest = manifest
        self.directory = modelDirectory
        self.computeUnits = computeUnits
    }

    private var modelURL: URL { directory.appendingPathComponent(manifest.modelFile) }
    private var vocabularyURL: URL { directory.appendingPathComponent(manifest.tokenizer.vocabFile) }

    public func availability() async -> AIAvailability {
        let files = FileManager.default
        guard (try? manifest.validate()) != nil else { return .unavailable(reason: .other("The model description is invalid")) }
        guard files.fileExists(atPath: modelURL.path), files.fileExists(atPath: vocabularyURL.path) else {
            return .unavailable(reason: .modelNotDownloaded(sizeBytes: manifest.model.totalBytes))
        }
        return .available
    }

    public func space() async throws -> EmbeddingSpace {
        try await load()
        guard let dimension else { throw AIError.unavailable(.modelNotReady) }
        return EmbeddingSpace(providerID: id, modelVersion: "\(manifest.model.id)@\(manifest.model.revision)",
                              dimension: dimension, maxInputTokens: manifest.maxSequenceLength,
                              queryPrefix: manifest.queryPrefix, documentPrefix: manifest.documentPrefix)
    }

    public func countTokens(_ text: String) async -> Int {
        if tokenizer == nil { tokenizer = try? WordPieceTokenizer(vocabularyFile: vocabularyURL, settings: manifest.tokenizer) }
        return tokenizer?.count(text) ?? TokenHeuristic.count(text)
    }

    public func embed(_ texts: [String], role: EmbeddingRole) async throws -> [[Float]] {
        try await load()
        guard let model, let tokenizer, let dimension else { throw AIError.unavailable(.modelNotReady) }
        let prefix = role == .query ? manifest.queryPrefix : manifest.documentPrefix
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            if Task.isCancelled { throw AIError.cancelled }
            let encoding = tokenizer.encode(prefix + text, maxLength: manifest.maxSequenceLength,
                                            padTo: manifest.fixedSequenceLength)
            vectors.append(try run(model, encoding, dimension: dimension))
        }
        return vectors
    }

    public func prewarm() async { try? await load() }

    public func unload() async {
        model = nil
    }

    private func load() async throws {
        if model != nil, tokenizer != nil, dimension != nil { return }
        guard await availability().isAvailable else {
            throw AIError.unavailable(.modelNotDownloaded(sizeBytes: manifest.model.totalBytes))
        }
        do {
            if tokenizer == nil {
                tokenizer = try WordPieceTokenizer(vocabularyFile: vocabularyURL, settings: manifest.tokenizer)
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            var url = modelURL
            if url.pathExtension == "mlpackage" {
                url = try await MLModel.compileModel(at: url)
            }
            let loaded = try MLModel(contentsOf: url, configuration: configuration)
            model = loaded
            dimension = manifest.dimension ?? Self.outputDimension(loaded, output: manifest.output)
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.providerFailed("the embedding model could not be loaded")
        }
        guard dimension != nil else { throw AIError.providerFailed("the embedding model has no known dimension") }
    }

    static func outputDimension(_ model: MLModel, output: String) -> Int? {
        guard let shape = model.modelDescription.outputDescriptionsByName[output]?.multiArrayConstraint?.shape,
              let last = shape.last?.intValue, last > 0 else { return nil }
        return last
    }

    private func run(_ model: MLModel, _ encoding: WordPieceTokenizer.Encoding, dimension: Int) throws -> [Float] {
        let length = encoding.ids.count
        var features: [String: MLFeatureValue] = [:]
        features[manifest.inputs.inputIDs] = MLFeatureValue(multiArray: try Self.array(encoding.ids))
        if let mask = manifest.inputs.attentionMask {
            features[mask] = MLFeatureValue(multiArray: try Self.array(encoding.attentionMask))
        }
        if let types = manifest.inputs.tokenTypeIDs {
            features[types] = MLFeatureValue(multiArray: try Self.array([Int32](repeating: 0, count: length)))
        }
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: try MLDictionaryFeatureProvider(dictionary: features))
        } catch {
            throw AIError.providerFailed("embedding inference failed")
        }
        guard let values = output.featureValue(for: manifest.output)?.multiArrayValue else {
            throw AIError.invalidOutput("missing embedding output")
        }
        let scalars = MLShapedArray<Float>(converting: values).scalars
        let pooled: [Float]
        switch (manifest.pooling, values.shape.count) {
        case (.none, _), (_, 2), (_, 1):
            pooled = Array(scalars.suffix(dimension))
        case (.cls, _):
            pooled = Array(scalars.prefix(dimension))
        case (.mean, _):
            var sum = [Float](repeating: 0, count: dimension)
            var count: Float = 0
            for token in 0..<min(length, scalars.count / dimension) where encoding.attentionMask[token] == 1 {
                for index in 0..<dimension { sum[index] += scalars[token * dimension + index] }
                count += 1
            }
            pooled = count > 0 ? sum.map { $0 / count } : sum
        }
        guard pooled.count == dimension else { throw AIError.invalidOutput("embedding of the wrong size") }
        return EmbeddingMath.normalized(pooled)
    }

    static func array(_ values: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
        return array
    }
}
