import Foundation
import OpenHumanAI
import Synchronization

public final class ScriptedProvider: AIProvider, Sendable {
    public let id: AIProviderID
    public let displayName: String
    private let caps: AICapabilities
    private let avail: AIAvailability
    private let version: String?
    private let fingerprint: String?
    private let respond: @Sendable (AIRequest, Int) -> FakeResponse
    private let recorded = Mutex<[AIRequest]>([])

    public init(
        id: AIProviderID = .fake,
        displayName: String = "Scripted model",
        capabilities: AICapabilities = .fake(),
        availability: AIAvailability = .available,
        modelVersion: String? = "scripted-1",
        consentFingerprint: String? = nil,
        respond: @escaping @Sendable (AIRequest, Int) -> FakeResponse = { request, _ in
            FakeAIProvider.cannedScript(request)
        }
    ) {
        self.id = id
        self.displayName = displayName
        self.caps = capabilities
        self.avail = availability
        self.version = modelVersion
        self.fingerprint = consentFingerprint
        self.respond = respond
    }

    public convenience init(
        id: AIProviderID = .fake, capabilities: AICapabilities = .fake(), responses: [FakeResponse]
    ) {
        self.init(id: id, capabilities: capabilities) { _, index in
            index < responses.count ? responses[index] : .fail(.providerFailed("no scripted response"))
        }
    }

    public func capabilities() async -> AICapabilities { caps }
    public func availability() async -> AIAvailability { avail }
    public func countTokens(_ text: String) async -> Int { TokenHeuristic.count(text) }
    public func modelVersion() async -> String? { version }
    public func consentFingerprint() async -> String? { fingerprint }

    public func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        let index = recorded.withLock { requests in
            requests.append(request)
            return requests.count - 1
        }
        return FakeAIProvider.stream(respond(request, index), providerID: id)
    }

    public var requests: [AIRequest] { recorded.withLock { $0 } }

    public func reset() { recorded.withLock { $0.removeAll() } }
}

public struct FakeClassifier: AIClassificationProvider {
    public let id: AIProviderID
    public let displayName: String
    public let dataLocation: AIDataLocation
    private let avail: AIAvailability
    private let version: String?
    private let result: @Sendable (ClassificationInput) throws -> TriageResult
    private let label: @Sendable (ClassificationInput) throws -> AutoLabelCategory?

    public init(
        id: AIProviderID = "local.classifier", displayName: String = "Fake classifier",
        dataLocation: AIDataLocation = .onDevice, availability: AIAvailability = .available,
        modelVersion: String? = "classifier-1",
        result: @escaping @Sendable (ClassificationInput) throws -> TriageResult = { _ in
            TriageResult(category: .newsletter, priority: 0, reason: "Looks like a newsletter.")
        },
        autoLabel: @escaping @Sendable (ClassificationInput) throws -> AutoLabelCategory? = { _ in nil }
    ) {
        self.id = id
        self.displayName = displayName
        self.dataLocation = dataLocation
        self.avail = availability
        self.version = modelVersion
        self.result = result
        self.label = autoLabel
    }

    public func availability() async -> AIAvailability { avail }
    public func modelVersion() async -> String? { version }
    public func classify(_ input: ClassificationInput) async throws -> TriageResult { try result(input) }
    public func autoLabel(_ input: ClassificationInput) async throws -> AutoLabelCategory? { try label(input) }

    public static func keywordAutoLabel(_ input: ClassificationInput) -> AutoLabelCategory? {
        let text = (input.subject.text + " " + input.excerpt.text).lowercased()
        let rules: [(AutoLabelCategory, [String])] = [
            (.invoice, ["invoice", "receipt", "payment", "bill"]),
            (.meeting, ["meeting", "invite", "calendar", "call at", "schedule"]),
            (.travel, ["flight", "booking", "itinerary", "hotel"]),
            (.news, ["newsletter", "digest", "weekly"]),
            (.marketing, ["sale", "offer", "% off", "deal"]),
            (.social, ["followed you", "mentioned you", "connection request"]),
            (.pitch, ["partnership", "quick question", "demo"]),
            (.respond, ["?", "can you", "could you", "please"]),
        ]
        return rules.first { _, words in words.contains { text.contains($0) } }?.0
    }
}

public actor RecordingActivitySink: AIActivitySink {
    public private(set) var records: [AIActivityRecord] = []
    public init() {}
    public func record(_ record: AIActivityRecord) async { records.append(record) }
}
