import Foundation

public enum AIFeature: String, Sendable, Hashable, Codable, CaseIterable, CodingKeyRepresentable {
    case summarize, replyOptions, rewrite, classify, askInbox
    case searchPlan
    case followUp
    case scheduling
}

public enum AITrigger: String, Sendable, Hashable, Codable {
    case user, automatic
}

public struct AIMessageInput: Sendable, Hashable {
    public var messageKey: String
    public var from: String
    public var date: Date
    public var bodyText: String
    public var subject: String?
    public var accountKey: String?

    public init(
        messageKey: String, from: String, date: Date, bodyText: String, subject: String? = nil, accountKey: String? = nil
    ) {
        self.messageKey = messageKey
        self.from = from
        self.date = date
        self.bodyText = bodyText
        self.subject = subject
        self.accountKey = accountKey
    }
}

public struct AIThreadInput: Sendable, Hashable {
    public var threadKey: String
    public var subject: String
    public var messages: [AIMessageInput]
    public var accountKey: String?
    public var trigger: AITrigger
    public var styleExamples: [String]

    public init(
        threadKey: String, subject: String, messages: [AIMessageInput], accountKey: String? = nil,
        trigger: AITrigger = .user, styleExamples: [String] = []
    ) {
        self.threadKey = threadKey
        self.subject = subject
        self.messages = messages
        self.accountKey = accountKey
        self.trigger = trigger
        self.styleExamples = styleExamples
    }

    public func upTo(_ messageKey: String) -> AIThreadInput? {
        guard let index = messages.firstIndex(where: { $0.messageKey == messageKey }) else { return nil }
        var copy = self
        copy.messages = Array(messages[...index])
        return copy
    }
}

public struct ReplyOption: Sendable, Hashable, Codable {
    public let label: String
    public let body: String
    public let linkHostsAddedByAI: [String]

    public init(label: String, body: String, linkHostsAddedByAI: [String] = []) {
        self.label = label
        self.body = body
        self.linkHostsAddedByAI = linkHostsAddedByAI
    }
}

public enum TriageCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case needsReply, fyi, newsletter, notification, receipt, calendar, personal, other
}

public struct TriageResult: Sendable, Hashable, Codable {
    public let category: TriageCategory
    public let priority: Int
    public let reason: String
    public let providerID: AIProviderID?

    public init(category: TriageCategory, priority: Int, reason: String, providerID: AIProviderID? = nil) {
        self.category = category
        self.priority = priority
        self.reason = reason
        self.providerID = providerID
    }
}

public struct AIProvenance: Sendable, Hashable {
    public var providerID: AIProviderID
    public var providerName: String
    public var dataLocation: AIDataLocation
    public var model: String?
    public var fromCache: Bool
    public var traceID: UUID?
    public var feature: AIFeature?
    public var promptID: PromptID?
    public var promptOverrideRevision: Int?

    public init(providerID: AIProviderID, providerName: String, dataLocation: AIDataLocation, model: String? = nil,
                fromCache: Bool = false, traceID: UUID? = nil, feature: AIFeature? = nil, promptID: PromptID? = nil,
                promptOverrideRevision: Int? = nil)
    {
        self.providerID = providerID
        self.providerName = providerName
        self.dataLocation = dataLocation
        self.model = model
        self.fromCache = fromCache
        self.traceID = traceID
        self.feature = feature
        self.promptID = promptID
        self.promptOverrideRevision = promptOverrideRevision
    }
}

public struct AIOutputReport: Sendable, Hashable {
    public var suspicious: Bool
    public var truncated: Bool
    public var usage: AIUsage?
    public var traceID: UUID?
    public var model: String?
    public var latency: Duration?
    public var firstToken: Duration?
    public var countedInputTokens: Int?

    public init(suspicious: Bool = false, truncated: Bool = false, usage: AIUsage? = nil, traceID: UUID? = nil,
                model: String? = nil, latency: Duration? = nil, firstToken: Duration? = nil,
                countedInputTokens: Int? = nil)
    {
        self.suspicious = suspicious
        self.truncated = truncated
        self.usage = usage
        self.traceID = traceID
        self.model = model
        self.latency = latency
        self.firstToken = firstToken
        self.countedInputTokens = countedInputTokens
    }
}

public enum SummaryEvent: Sendable {
    case started(AIProvenance)
    case textDelta(String)
    case completed(AIOutputReport)
}

public enum RewriteEvent: Sendable {
    case started(AIProvenance)
    case textDelta(String)
    case completed(AIOutputReport)
}

public enum AskInboxEvent: Sendable {
    case started(AIProvenance)
    case textDelta(String)
    case citations([String])
    case completed(AIOutputReport)
}

public struct ReplyOptionsResult: Sendable, Hashable {
    public var options: [ReplyOption]
    public var provenance: AIProvenance
    public var report: AIOutputReport

    public init(options: [ReplyOption], provenance: AIProvenance, report: AIOutputReport) {
        self.options = options
        self.provenance = provenance
        self.report = report
    }
}

public struct FeatureStatus: Sendable, Hashable {
    public var feature: AIFeature
    public var availability: AIAvailability
    public var providerID: AIProviderID?
    public var providerName: String?
    public var dataLocation: AIDataLocation?

    public init(feature: AIFeature, availability: AIAvailability, providerID: AIProviderID? = nil,
                providerName: String? = nil, dataLocation: AIDataLocation? = nil)
    {
        self.feature = feature
        self.availability = availability
        self.providerID = providerID
        self.providerName = providerName
        self.dataLocation = dataLocation
    }
}

public protocol AIFeatures: Sendable {
    func summarize(_ thread: AIThreadInput) -> AsyncThrowingStream<SummaryEvent, Error>
    func summarizeLine(_ thread: AIThreadInput) async throws -> ThreadLineSummary
    func replyOptionsResult(_ thread: AIThreadInput, userName: String) async throws -> ReplyOptionsResult
    func rewriteEvents(_ text: String, instruction: String, context: AIThreadInput?)
        -> AsyncThrowingStream<RewriteEvent, Error>
    func classify(_ thread: AIThreadInput) async throws -> TriageResult
    func askInbox(_ question: String, candidates: [AIMessageInput]) -> AsyncThrowingStream<AskInboxEvent, Error>
    func status(for feature: AIFeature, accountKey: String?) async -> FeatureStatus
    func planSearch(_ text: String, accountKey: String?) async throws -> SearchPlanResult
    func searchWithTool(_ text: String, accountKey: String?, backend: any AISearchToolBackend) async throws
        -> SearchToolResult
    func detectFollowUp(_ input: FollowUpInput) async throws -> FollowUpResult
    func extractSchedulingTimes(_ input: SchedulingExtractInput) async throws -> [SchedulingExtractedTime]
    func draftSchedulingReply(_ input: SchedulingDraftInput) async throws -> SchedulingDraftResult
}

extension AIFeatures {
    public func planSearch(_ text: String, accountKey: String?) async throws -> SearchPlanResult {
        throw AIError.unavailable(.disabledBySettings)
    }

    public func searchWithTool(_ text: String, accountKey: String?, backend: any AISearchToolBackend) async throws
        -> SearchToolResult
    {
        throw AIError.unavailable(.disabledBySettings)
    }

    public func detectFollowUp(_ input: FollowUpInput) async throws -> FollowUpResult {
        throw AIError.unavailable(.disabledBySettings)
    }

    public func replyOptions(_ thread: AIThreadInput, userName: String) async throws -> [ReplyOption] {
        try await replyOptionsResult(thread, userName: userName).options
    }

    public func rewrite(_ text: String, instruction: String, context: AIThreadInput?)
        -> AsyncThrowingStream<String, Error>
    {
        let events = rewriteEvents(text, instruction: instruction, context: context)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case .textDelta(let text) = event { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func status(for feature: AIFeature) async -> FeatureStatus {
        await status(for: feature, accountKey: nil)
    }
}
