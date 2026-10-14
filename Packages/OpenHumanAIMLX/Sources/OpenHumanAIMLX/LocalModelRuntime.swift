import Foundation
import OpenHumanAI
import OpenHumanAIModelStore

public protocol LocalModelRuntime: Sendable {
    func load(modelDirectory: URL, manifest: ModelManifest) async throws -> any LocalModelSession
}

public protocol LocalModelSession: Sendable {
    var contextSize: Int? { get }
    func countTokens(_ text: String) async -> Int?
    func generate(system: String, input: String, maxTokens: Int, temperature: Double?) -> AsyncThrowingStream<String, Error>
    func unload() async
}

public struct UnlinkedLocalModelRuntime: LocalModelRuntime {
    public init() {}

    public func load(modelDirectory: URL, manifest: ModelManifest) async throws -> any LocalModelSession {
        throw AIError.unavailable(.other("This build does not include the local model runtime"))
    }
}
