import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import OpenHumanAI
import OpenHumanAIMLX
import OpenHumanAIModelStore

public struct MLXLocalModelRuntime: LocalModelRuntime {
    public struct Limits: Sendable, Hashable {
        public var cacheLimitBytes: Int
        public var maxKVTokens: Int

        public init(cacheLimitBytes: Int = 64 * 1_048_576, maxKVTokens: Int = 4_096) {
            self.cacheLimitBytes = cacheLimitBytes
            self.maxKVTokens = maxKVTokens
        }
    }

    public let limits: Limits

    public init(limits: Limits = Limits()) { self.limits = limits }

    public func load(modelDirectory: URL, manifest: ModelManifest) async throws -> any LocalModelSession {
        let tokenizer: ByteLevelBPETokenizer
        do {
            tokenizer = try ByteLevelBPETokenizer(
                contentsOf: modelDirectory.appendingPathComponent("tokenizer.json"), eosToken: Qwen3ChatTemplate.eosToken)
        } catch {
            throw AIError.providerFailed("The classifier model's tokenizer could not be read.")
        }
        Memory.cacheLimit = limits.cacheLimitBytes
        let bridge = MLXTokenizerBridge(base: tokenizer)
        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory, using: FixedTokenizerLoader(tokenizer: bridge))
        } catch {
            throw AIError.providerFailed("The classifier model could not be loaded (\(type(of: error))).")
        }
        return MLXLocalModelSession(
            container: container, tokenizer: tokenizer, contextSize: manifest.declaredContextTokens,
            maxKVTokens: limits.maxKVTokens)
    }
}

final class MLXLocalModelSession: LocalModelSession {
    private let container: ModelContainer
    private let tokenizer: ByteLevelBPETokenizer
    let contextSize: Int?
    private let maxKVTokens: Int

    init(container: ModelContainer, tokenizer: ByteLevelBPETokenizer, contextSize: Int?, maxKVTokens: Int) {
        self.container = container
        self.tokenizer = tokenizer
        self.contextSize = contextSize
        self.maxKVTokens = maxKVTokens
    }

    func countTokens(_ text: String) async -> Int? { tokenizer.encode(text, allowSpecialTokens: false).count }

    func generate(system: String, input: String, maxTokens: Int, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        let container = self.container
        let maxKV = maxKVTokens
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let userInput = UserInput(chat: [.system(system), .user(input)])
                    let prepared = try await container.prepare(input: userInput)
                    let parameters = GenerateParameters(
                        maxTokens: maxTokens, maxKVSize: maxKV, temperature: Float(temperature ?? 0))
                    let stream = try await container.generate(input: prepared, parameters: parameters)
                    for await event in stream {
                        try Task.checkCancellation()
                        if case .chunk(let text) = event { continuation.yield(text) }
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func unload() async { Memory.clearCache() }
}

struct FixedTokenizerLoader: TokenizerLoader {
    let tokenizer: MLXTokenizerBridge
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer { tokenizer }
}

struct MLXTokenizerBridge: MLXLMCommon.Tokenizer {
    let base: ByteLevelBPETokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { base.encode(text, allowSpecialTokens: true) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { base.id(for: token) }
    func convertIdToToken(_ id: Int) -> String? { base.token(for: id) }
    var bosToken: String? { nil }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { nil }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        let turns = messages.compactMap { message -> (role: String, content: String)? in
            guard let role = message["role"] as? String, role == "system" || role == "user",
                  let content = message["content"] as? String else { return nil }
            return (role, content)
        }
        return try Qwen3ChatTemplate.encode(turns, tokenizer: base)
    }
}
