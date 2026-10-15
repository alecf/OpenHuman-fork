import Foundation

public enum AIPolicy {
    public static let reservedSummaryTokens = 200
    public static let reservedChunkSummaryTokens = 120
    public static let reservedReduceTokens = 200
    public static let reservedReplyOptionsTokens = 450
    public static let reservedTriageTokens = 80
    public static let reservedSearchPlanTokens = 160
    public static let reservedSearchToolTokens = 120
    public static let searchToolMaxCalls = 3
    public static let searchToolMaxHits = 8
    public static let searchToolSnippetCharacters = 200
    public static let searchToolMaxKeywords = 6
    public static let searchToolMaxDays = 3650
    public static let reservedFollowUpTokens = 80

    public static let safetyMarginFraction = 0.10
    public static let overflowShrinkFactor = 0.75
    public static let reduceGroupSize = 8
    public static let replyLastMessageBudgetFraction = 0.6
    public static let rewriteSelectionBudgetFraction = 0.6
    public static let classifyExcerptCharacters = 1_500
    public static let askInboxExcerptCharacters = 400
    public static let askInboxExcerptStep = 64
    public static let askInboxInputBudgetFraction = 0.6
    public static let askInboxMaxCandidates = 20
    public static let askInboxTimeout: Duration = .seconds(45)
    public static let agentCLIDefaultInputCap = 32_000
    public static let autoSummarizeMinimumMessages = 3

    public static let subjectCharacterCap = 300
    public static let senderCharacterCap = 200
    public static let userNameCharacterCap = 100
    public static let userInstructionCharacterCap = 2_000
    public static let messageCharacterCap = 100_000

    public static let replyOptionCount = 3
    public static let replyOptionBodyCharacters = 1_200
    public static let replyOptionLabelWords = 4
    public static let replyOptionLabelCharacters = 40
    public static let triageReasonCharacters = 120
    public static let searchQuestionCharacterCap = 300
    public static let searchPlanMaxKeywords = 6
    public static let searchPlanKeywordCharacters = 40
    public static let searchPlanMaxPeople = 3
    public static let searchPlanTopicWords = 12
    public static let followUpReasonWords = 12
    public static let followUpReasonCharacters = 100
    public static let followUpMaxDays = 14
    public static let followUpMessageCharacters = 4_000
    public static let followUpContextMessages = 3
    public static let followUpContextCharacters = 1_000
    public static let outputByteCap = 1_000_000

    public static let replyOptionsTTL: Duration = .seconds(24 * 3600)
    public static let appleCloudTTL: Duration = .seconds(24 * 3600)

    public static let truncationMarker = "[truncated]"
}
