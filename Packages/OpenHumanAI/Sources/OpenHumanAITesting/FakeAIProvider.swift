import Foundation
import OpenHumanAI

extension AICapabilities {
    public static func fake(
        contextTokens: Int? = 4096, policyInputCap: Int? = nil, dataLocation: AIDataLocation = .onDevice,
        structuredOutput: StructuredOutputSupport = .promptedJSON, streaming: Bool = true
    ) -> AICapabilities {
        AICapabilities(
            contextTokens: contextTokens, policyInputCap: policyInputCap, tokenCounting: .heuristic,
            streaming: streaming, structuredOutput: structuredOutput, dataLocation: dataLocation,
            typicalLatency: .interactive)
    }
}

public enum FakeResponse: Sendable {
    case text(String, chunkSize: Int = 16, delay: Duration = .zero)
    case json(Data)
    case fail(AIError)
    case hang
}

public struct FakeAIProvider: AIProvider {
    public let id: AIProviderID
    public let displayName: String
    private let caps: AICapabilities
    private let avail: AIAvailability
    private let version: String?
    private let fingerprint: String?
    private let script: @Sendable (AIRequest) -> FakeResponse

    public init(
        id: AIProviderID = .fake,
        displayName: String = "Fake model",
        capabilities: AICapabilities = .fake(contextTokens: 4096),
        availability: AIAvailability = .available,
        modelVersion: String? = "fake-1",
        consentFingerprint: String? = nil,
        script: @escaping @Sendable (AIRequest) -> FakeResponse = FakeAIProvider.cannedScript
    ) {
        self.id = id
        self.displayName = displayName
        self.caps = capabilities
        self.avail = availability
        self.version = modelVersion
        self.fingerprint = consentFingerprint
        self.script = script
    }

    public func capabilities() async -> AICapabilities { caps }
    public func availability() async -> AIAvailability { avail }
    public func countTokens(_ text: String) async -> Int { TokenHeuristic.count(text) }
    public func modelVersion() async -> String? { version }
    public func consentFingerprint() async -> String? { fingerprint }

    public func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        FakeAIProvider.stream(script(request), providerID: id)
    }

    public static func stream(_ response: FakeResponse, providerID: AIProviderID, usage: AIUsage? = nil)
        -> AsyncThrowingStream<AIEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(providerID: providerID, model: "fake"))
                switch response {
                case .text(let text, let chunkSize, let delay):
                    var rest = Substring(text)
                    while !rest.isEmpty {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        let piece = rest.prefix(max(1, chunkSize))
                        rest = rest.dropFirst(piece.count)
                        continuation.yield(.textDelta(String(piece)))
                        if delay > .zero { try? await Task.sleep(for: delay) }
                    }
                    continuation.yield(.finished(usage: usage))
                    continuation.finish()
                case .json(let data):
                    continuation.yield(.structured(data))
                    continuation.yield(.finished(usage: usage))
                    continuation.finish()
                case .fail(let error):
                    continuation.finish(throwing: error)
                case .hang:
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                    continuation.finish(throwing: CancellationError())
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static let cannedScript: @Sendable (AIRequest) -> FakeResponse = { request in
        let emails = request.untrusted.filter { $0.kind == .emailBody || $0.kind == .summary }.count
        switch request.task {
        case .summarize, .reduce:
            return .text("Summary of \(emails) messages: the sender asks for a reply by Friday; nothing is decided yet.")
        case .summarizeChunk:
            return .text("Sender: asks a question and proposes a time.")
        case .replyOptions:
            return .text(
                #"{"options":[{"label":"Sounds good","body":"Sounds good, thanks."},"#
                    + #"{"label":"Not this time","body":"Thanks, but I can't make it."},"#
                    + #"{"label":"Ask for details","body":"Could you share a few more details first?"}]}"#)
        case .rewrite:
            let draft = request.untrusted.first { $0.kind == .draft }?.text ?? ""
            return .text(draft.isEmpty ? "Rewritten text." : "Rewritten: " + draft)
        case .classify:
            return .text(#"{"category":"fyi","priority":1,"reason":"Information only."}"#)
        case .askInbox:
            let first = request.untrusted.first { $0.kind == .excerpt }?.id
            return .text("Here is what the emails say.\nSources: \(first ?? "")")
        case .searchPlan:
            let question = request.trusted.first { $0.kind == .userQuestion }?.text ?? ""
            let word = question.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? "mail"
            return .text(#"{"keywords":[""# + word.lowercased() + #""],"from":[],"to":[],"timeframe":"none","mailbox":"any"}"#)
        case .scheduling:
            if request.output.schema != nil {
                return .text(#"{"times":[{"day":"tomorrow","start":"2pm","end":"","zone":""}]}"#)
            }
            let plan = request.trusted.first { $0.kind == .userInstruction }?.text ?? ""
            return .text("Thanks for the note.\n\n" + plan.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
                .joined(separator: "\n") + "\n\nBest")
        case .followUp:
            let sent = request.untrusted.last { $0.kind == .emailBody }?.text ?? ""
            return .text(sent.contains("?")
                ? #"{"needsFollowUp":true,"reason":"Asked a question","suggestedDays":null}"#
                : #"{"needsFollowUp":false,"reason":"Nothing is asked of them","suggestedDays":null}"#)
        }
    }
}
