import Foundation
import MailModel
import OpenHumanAI
import OpenHumanCore

public struct AskSource: Identifiable, Hashable, Sendable {
    public let id: MessageKey
    public let thread: ThreadKey
    public let sender: String
    public let subject: String
    public let date: Date

    public init(id: MessageKey, thread: ThreadKey, sender: String, subject: String, date: Date) {
        self.id = id
        self.thread = thread
        self.sender = sender
        self.subject = subject
        self.date = date
    }
}

public enum AskFailure: Equatable, Sendable {
    case aiOff
    case unavailable(String)
    case needsConsent(AIProviderID)
    case onDeviceOnly
    case tooMuch
    case refused
    case timedOut
    case blocked
    case failed(String)
}

public struct AskCompleteness: Hashable, Sendable {
    public var searchedBack: Date?

    public init(searchedBack: Date? = nil) {
        self.searchedBack = searchedBack
    }
}

public enum OlderMailState: Equatable, Sendable {
    case available(searchedBack: Date?)
    case offline
    case searching
    case failed
    case done
}

public struct AskPlan: Hashable, Sendable {
    public var query: String
    public var chips: [String]
    public var semanticText: String?

    public init(query: String, chips: [String], semanticText: String? = nil) {
        self.query = query
        self.chips = chips
        self.semanticText = semanticText
    }
}

public protocol AskPlanning: Sendable {
    func plan(_ question: String, account: AccountID?) async -> AskPlan?
}

public protocol AskRetrieving: Sendable {
    func retrieve(_ question: String, scope: AskModel.Scope, plan: AskPlan?) async throws -> AskRetrieval
    func retrieveOlderMail(_ question: String, gmailQuery: String, account: AccountID) async throws -> AskRetrieval
}

public struct AskRetrieval: Sendable {
    public var candidates: [AIMessageInput]
    public var keys: [String: MessageKey]
    public var sources: [String: AskSource]
    public var otherThreads: [AskSource]
    public var queryText: String?
    public var queryAccount: AccountID?
    public var gmailQuery: String?
    public var searched: String
    public var planLine: String
    public var completeness: AskCompleteness?

    public init(candidates: [AIMessageInput], keys: [String: MessageKey], sources: [String: AskSource],
                otherThreads: [AskSource], queryText: String?, queryAccount: AccountID?, gmailQuery: String?,
                searched: String, planLine: String, completeness: AskCompleteness?) {
        self.candidates = candidates
        self.keys = keys
        self.sources = sources
        self.otherThreads = otherThreads
        self.queryText = queryText
        self.queryAccount = queryAccount
        self.gmailQuery = gmailQuery
        self.searched = searched
        self.planLine = planLine
        self.completeness = completeness
    }
}

public enum AskRetrievalError: Error, Equatable, Sendable {
    case noUsableWords
    case conversationGone
}

public enum AskCueWords {
    static let time: Set<String> = [
        "today", "yesterday", "last", "this", "past", "ago", "since", "before", "after", "week", "month", "year",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march",
        "april", "may", "june", "july", "august", "september", "october", "november", "december",
    ]
    static let people: Set<String> = ["from", "to", "with", "by", "sent", "wrote", "emailed"]
    static let attributes: Set<String> = ["attachment", "attached", "pdf", "spreadsheet", "invite", "unread", "starred"]
    static let all = time.union(people).union(attributes)

    public static func containsCue(_ text: String) -> Bool {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).contains { all.contains(String($0)) }
    }
}
