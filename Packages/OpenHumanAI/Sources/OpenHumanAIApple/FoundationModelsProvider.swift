import Foundation
import FoundationModels
import OpenHumanAI
import Synchronization

@available(macOS 27, iOS 27, *)
public struct FoundationModelsProvider<Source: FMModelSource>: AIProvider {
    private let source: Source
    private let cache = RuntimeCache()

    public init(source: Source) { self.source = source }

    public var id: AIProviderID { source.providerID }
    public var displayName: String { source.displayName }

    private final class RuntimeCache: Sendable {
        struct Values {
            var contextSize: Int?
            var hasTokenizer: Bool?
            var guided: Bool?
        }
        let values = Mutex(Values())
    }

    public func capabilities() async -> AICapabilities {
        let available = await source.availability().isAvailable
        var snapshot = cache.values.withLock { $0 }
        if available, snapshot.contextSize == nil || snapshot.hasTokenizer == nil || snapshot.guided == nil {
            if snapshot.contextSize == nil { snapshot.contextSize = await source.contextSize() }
            if snapshot.hasTokenizer == nil { snapshot.hasTokenizer = await source.tokenCount(for: "token") != nil }
            if snapshot.guided == nil { snapshot.guided = await source.supportsGuidedGeneration() }
            cache.values.withLock { $0 = snapshot }
        }
        return AICapabilities(
            contextTokens: snapshot.contextSize, policyInputCap: nil,
            tokenCounting: snapshot.hasTokenizer == true ? .exact : .heuristic, streaming: true,
            structuredOutput: snapshot.guided == true ? .native : .promptedJSON, dataLocation: source.dataLocation,
            typicalLatency: source.dataLocation == .onDevice ? .interactive : .slow)
    }

    public func availability() async -> AIAvailability { await source.availability() }

    public func countTokens(_ text: String) async -> Int {
        if let count = await source.tokenCount(for: text) { return count }
        return TokenHeuristic.count(text)
    }

    public func modelVersion() async -> String? { await source.modelVersion() }

    public func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await execute(request, into: continuation)
                    continuation.finish()
                } catch {
                    let mapped = FMErrorMapping.map(
                        error, estimatedTokens: TokenHeuristic.count(request.renderedInput()),
                        contextLimit: cache.values.withLock { $0.contextSize })
                    continuation.finish(throwing: mapped)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(_ request: AIRequest, into continuation: AsyncThrowingStream<AIEvent, Error>.Continuation) async throws {
        let availability = await source.availability()
        guard availability.isAvailable else {
            throw AIError.unavailable(availability.unavailableReason ?? .other("Unavailable"))
        }
        let model = try await source.makeModel(for: request.task)
        var tools: [any Tool] = []
        if let search = request.searchTool, source.dataLocation == .onDevice { tools.append(FMSearchMailTool(session: search)) }
        let session = LanguageModelSession(model: model, tools: tools, instructions: request.system)
        let options = GenerationOptions(temperature: request.temperature, maximumResponseTokens: request.output.maxTokens)
        let input = request.renderedInput()
        continuation.yield(.started(providerID: id, model: source.modelLabel()))

        let guided = await source.supportsGuidedGeneration()
        if guided, let schema = request.output.schema, schema == OutputGuard.triageSchema {
            let response = try await session.respond(to: input, generating: FMTriage.self, options: options)
            continuation.yield(.structured(response.content.json))
            continuation.yield(.finished(usage: Self.usage(response.usage)))
            return
        }
        if guided, let schema = request.output.schema, schema == OutputGuard.replyOptionsSchema {
            let response = try await session.respond(to: input, generating: FMReplyOptions.self, options: options)
            continuation.yield(.structured(response.content.json))
            continuation.yield(.finished(usage: Self.usage(response.usage)))
            return
        }
        if guided, let schema = request.output.schema, schema == OutputGuard.searchPlanSchema {
            let response = try await session.respond(to: input, generating: FMSearchPlan.self, options: options)
            continuation.yield(.structured(response.content.json))
            continuation.yield(.finished(usage: Self.usage(response.usage)))
            return
        }
        if guided, let schema = request.output.schema, schema == OutputGuard.followUpSchema {
            let response = try await session.respond(to: input, generating: FMFollowUp.self, options: options)
            continuation.yield(.structured(response.content.json))
            continuation.yield(.finished(usage: Self.usage(response.usage)))
            return
        }

        var emitted = ""
        var usage: AIUsage?
        for try await snapshot in session.streamResponse(to: input, options: options) {
            let text = snapshot.content
            if text.hasPrefix(emitted), text.count > emitted.count {
                continuation.yield(.textDelta(String(text.dropFirst(emitted.count))))
                emitted = text
            }
            usage = Self.usage(snapshot.usage)
        }
        continuation.yield(.finished(usage: usage))
    }

    private static func usage(_ usage: LanguageModelSession.Usage) -> AIUsage {
        AIUsage(
            inputTokens: usage.input.totalTokenCount, outputTokens: usage.output.totalTokenCount,
            cachedTokens: usage.input.cachedTokenCount, reasoningTokens: usage.output.reasoningTokenCount)
    }
}

@available(macOS 27, iOS 27, *)
public typealias AppleSystemProvider = FoundationModelsProvider<SystemModelSource>
@available(macOS 27, iOS 27, *)
public typealias ApplePrivateCloudComputeProvider = FoundationModelsProvider<PrivateCloudComputeSource>
