import Foundation
import OpenHumanAI
import Synchronization

public final class FakeSearchToolBackend: AISearchToolBackend, Sendable {
    private let all: [AISearchToolHit]
    private let recorded = Mutex<[AISearchToolQuery]>([])

    public init(hits: [AISearchToolHit]) { all = hits }

    public var queries: [AISearchToolQuery] { recorded.withLock { $0 } }

    public func search(_ query: AISearchToolQuery) async throws -> [AISearchToolHit] {
        recorded.withLock { $0.append(query) }
        return all.filter { hit in
            let text = (hit.sender + " " + hit.subject + " " + hit.snippet).lowercased()
            return query.keywords.allSatisfy { text.contains($0.lowercased()) }
                && (query.sender.isEmpty || hit.sender.lowercased().contains(query.sender.lowercased()))
        }
    }
}

public final class FakeSearchToolProvider: AIProvider, Sendable {
    public let id: AIProviderID
    public let displayName = "Fake tool model"
    private let caps: AICapabilities
    private let avail: AIAvailability
    private let calls: [AISearchToolQuery]
    private let answer: String
    private let recorded = Mutex<[AIRequest]>([])
    private let outputs = Mutex<[String]>([])

    public init(id: AIProviderID = .appleSystem, capabilities: AICapabilities = .fake(),
                availability: AIAvailability = .available, calls: [AISearchToolQuery],
                answer: String = "Found it.") {
        self.id = id
        caps = capabilities
        avail = availability
        self.calls = calls
        self.answer = answer
    }

    public func capabilities() async -> AICapabilities { caps }
    public func availability() async -> AIAvailability { avail }
    public func countTokens(_ text: String) async -> Int { TokenHeuristic.count(text) }
    public func modelVersion() async -> String? { "fake-tool-1" }

    public var requests: [AIRequest] { recorded.withLock { $0 } }
    public var toolOutputs: [String] { outputs.withLock { $0 } }

    public func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        recorded.withLock { $0.append(request) }
        let calls = self.calls
        let answer = self.answer
        let id = self.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.started(providerID: id, model: "fake-tool-1"))
                    if let tool = request.searchTool {
                        for call in calls { outputs.withLock { $0.append("") }; let text = try await tool.call(call); outputs.withLock { $0[$0.count - 1] = text } }
                    }
                    continuation.yield(.textDelta(answer))
                    continuation.yield(.finished(usage: nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
