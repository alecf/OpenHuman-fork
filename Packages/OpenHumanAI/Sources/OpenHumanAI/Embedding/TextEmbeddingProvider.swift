import Foundation

public enum EmbeddingRole: String, Sendable, Hashable, Codable {
    case document, query
}

public struct EmbeddingSpace: Hashable, Sendable, Codable {
    public var providerID: AIProviderID
    public var modelVersion: String
    public var dimension: Int
    public var maxInputTokens: Int?
    public var queryPrefix: String
    public var documentPrefix: String
    public var recipe: String
    public var id: String

    public init(providerID: AIProviderID, modelVersion: String, dimension: Int, maxInputTokens: Int?,
                queryPrefix: String = "", documentPrefix: String = "", recipe: String = EmbeddingRecipe.mailV1) {
        self.providerID = providerID
        self.modelVersion = modelVersion
        self.dimension = dimension
        self.maxInputTokens = maxInputTokens
        self.queryPrefix = queryPrefix
        self.documentPrefix = documentPrefix
        self.recipe = recipe
        self.id = Self.makeID(providerID: providerID, modelVersion: modelVersion, dimension: dimension,
                              maxInputTokens: maxInputTokens, queryPrefix: queryPrefix, documentPrefix: documentPrefix,
                              recipe: recipe)
    }

    public static func makeID(providerID: AIProviderID, modelVersion: String, dimension: Int, maxInputTokens: Int?,
                              queryPrefix: String, documentPrefix: String, recipe: String) -> String {
        String(Digest.sha256Hex([
            "space.v1", providerID.rawValue, modelVersion, String(dimension), maxInputTokens.map(String.init) ?? "-",
            queryPrefix, documentPrefix, recipe,
        ]).prefix(16))
    }

    public var isConsistent: Bool {
        id == Self.makeID(providerID: providerID, modelVersion: modelVersion, dimension: dimension,
                          maxInputTokens: maxInputTokens, queryPrefix: queryPrefix, documentPrefix: documentPrefix,
                          recipe: recipe)
    }

    public func prefix(for role: EmbeddingRole) -> String {
        role == .query ? queryPrefix : documentPrefix
    }
}

public protocol TextEmbeddingProvider: Sendable {
    var id: AIProviderID { get }
    var displayName: String { get }
    var dataLocation: AIDataLocation { get }
    var preferredBatchSize: Int { get }
    func availability() async -> AIAvailability
    func space() async throws -> EmbeddingSpace
    func countTokens(_ text: String) async -> Int
    func embed(_ texts: [String], role: EmbeddingRole) async throws -> [[Float]]
    func prewarm() async
    func unload() async
}

extension TextEmbeddingProvider {
    public func embed(_ text: String, role: EmbeddingRole) async throws -> [Float] {
        guard let vector = try await embed([text], role: role).first else {
            throw AIError.invalidOutput("no vector")
        }
        return vector
    }
}

public enum EmbeddingProviders {
    public static func onDeviceOnly(_ provider: any TextEmbeddingProvider) -> (any TextEmbeddingProvider)? {
        provider.dataLocation == .onDevice ? provider : nil
    }

    public static let evalChosenDefault: AIProviderID? = nil

    public static let appleSentence: AIProviderID = "apple.nl.sentence"
    public static let appleContextual: AIProviderID = "apple.nl.contextual"
    public static let bgeSmall: AIProviderID = .local("bge-small-en")
}

public enum EmbeddingMath {
    public static func normalized(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        for value in vector { sum += value * value }
        guard sum > 0, sum.isFinite else {
            var unit = [Float](repeating: 0, count: max(vector.count, 1))
            unit[0] = 1
            return unit
        }
        let scale = 1 / sum.squareRoot()
        return vector.map { $0 * scale }
    }

    public static func normalized(_ vector: [Double]) -> [Float] {
        normalized(vector.map { Float($0) })
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count) { sum += a[index] * b[index] }
        return sum
    }

    public static func isUnitLength(_ vector: [Float], tolerance: Float = 1e-3) -> Bool {
        abs(dot(vector, vector) - 1) <= tolerance
    }

    public static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == first.count {
            for index in 0..<vector.count { sum[index] += vector[index] }
        }
        let count = Float(vectors.count)
        return sum.map { $0 / count }
    }
}
