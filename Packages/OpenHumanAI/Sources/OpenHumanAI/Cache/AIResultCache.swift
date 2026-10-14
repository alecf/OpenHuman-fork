import CryptoKit
import Foundation

public struct AICacheKey: Hashable, Sendable, Codable {
    public let digest: String
    public let threadKey: String?

    public init(
        providerID: AIProviderID, modelVersion: String, promptID: PromptID, promptDigest: String, task: AITask,
        inputsDigest: String, threadKey: String?
    ) {
        digest = Digest.sha256Hex([
            "v1", providerID.rawValue, modelVersion, promptID.description, promptDigest, task.rawValue, inputsDigest,
        ])
        self.threadKey = threadKey
    }

    public init(digest: String, threadKey: String?) {
        self.digest = digest
        self.threadKey = threadKey
    }
}

public struct CachedAIResult: Sendable, Hashable, Codable {
    public enum Payload: Sendable, Hashable, Codable {
        case text(String)
        case json(Data)
    }

    public var payload: Payload
    public var providerID: AIProviderID
    public var providerName: String
    public var dataLocation: AIDataLocation
    public var model: String?
    public var createdAt: Date

    public init(payload: Payload, providerID: AIProviderID, providerName: String, dataLocation: AIDataLocation,
                model: String?, createdAt: Date)
    {
        self.payload = payload
        self.providerID = providerID
        self.providerName = providerName
        self.dataLocation = dataLocation
        self.model = model
        self.createdAt = createdAt
    }

    public var provenance: AIProvenance {
        AIProvenance(providerID: providerID, providerName: providerName, dataLocation: dataLocation, model: model,
                     fromCache: true)
    }
}

public protocol AIResultCache: Sendable {
    func get(_ key: AICacheKey) async -> CachedAIResult?
    func put(_ key: AICacheKey, _ value: CachedAIResult, ttl: Duration?) async
    func invalidate(threadKey: String) async
    func removeAll() async
}

public enum Digest {
    public static func sha256Hex(_ components: [String]) -> String {
        var hasher = SHA256()
        for component in components {
            let bytes = Data(component.utf8)
            hasher.update(data: Data("\(bytes.count):".utf8))
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func inputs(of request: AIRequest, extra: [String] = []) -> String {
        var components = ["task", request.task.rawValue, "output", "\(request.output.maxTokens)"]
        if let schema = request.output.schema { components += ["schema", schema.jsonString] }
        for part in request.trusted { components += ["t", part.kind.rawValue, part.text] }
        for part in request.untrusted {
            components += ["u", part.kind.rawValue, part.id, part.date.map { "\($0.timeIntervalSince1970)" } ?? "-", part.text]
        }
        return sha256Hex(components + extra)
    }
}
