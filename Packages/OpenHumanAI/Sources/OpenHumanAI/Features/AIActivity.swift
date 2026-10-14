import Foundation

public struct AIActivityRecord: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        case completed
        case cached
        case failed(String)
        case cancelled
    }

    public var date: Date
    public var feature: AIFeature
    public var task: AITask
    public var providerID: AIProviderID
    public var dataLocation: AIDataLocation
    public var threadKey: String?
    public var countedInputTokens: Int
    public var inputBudget: Int?
    public var contextTokens: Int?
    public var usage: AIUsage?
    public var outcome: Outcome

    public init(date: Date, feature: AIFeature, task: AITask, providerID: AIProviderID, dataLocation: AIDataLocation,
                threadKey: String?, countedInputTokens: Int, inputBudget: Int?, contextTokens: Int?, usage: AIUsage?,
                outcome: Outcome)
    {
        self.date = date
        self.feature = feature
        self.task = task
        self.providerID = providerID
        self.dataLocation = dataLocation
        self.threadKey = threadKey
        self.countedInputTokens = countedInputTokens
        self.inputBudget = inputBudget
        self.contextTokens = contextTokens
        self.usage = usage
        self.outcome = outcome
    }
}

public protocol AIActivitySink: Sendable {
    func record(_ record: AIActivityRecord) async
}
