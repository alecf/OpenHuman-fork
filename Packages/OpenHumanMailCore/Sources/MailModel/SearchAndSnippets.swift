import Foundation
import OpenHumanCore

public struct PageCursor: Hashable, Sendable, Codable {
    public let payload: Data

    public init(payload: Data) {
        self.payload = payload
    }
}

public struct SearchHitInfo: Sendable, Hashable, Identifiable {
    public let row: ThreadRow
    public let matchedMessageRowIDs: [Int64]
    public let highlight: String?
    public let searchMatch: SearchMatchKind?

    public init(row: ThreadRow, matchedMessageRowIDs: [Int64] = [], highlight: String? = nil,
                searchMatch: SearchMatchKind? = nil) {
        self.row = row
        self.matchedMessageRowIDs = matchedMessageRowIDs
        self.highlight = highlight
        self.searchMatch = searchMatch
    }

    public var id: ThreadKey { row.id }
}

public struct SearchResultsInfo: Sendable, Hashable {
    public let hits: [SearchHitInfo]
    public let hasMore: Bool
    public let completeness: SearchCompletenessInfo

    public init(hits: [SearchHitInfo], hasMore: Bool, completeness: SearchCompletenessInfo = .complete) {
        self.hits = hits
        self.hasMore = hasMore
        self.completeness = completeness
    }
}

public enum SearchIncompleteness: Sendable, Hashable {
    case olderMailNotLocal(searchedBack: Date?)
    case bodiesNotDownloaded(messages: Int)
    case tooManyMatches(limit: Int)
}

public struct SearchCompletenessInfo: Sendable, Hashable {
    public let reasons: [SearchIncompleteness]

    public init(reasons: [SearchIncompleteness] = []) {
        self.reasons = reasons
    }

    public var isComplete: Bool { reasons.isEmpty }

    public static let complete = SearchCompletenessInfo()
}

public enum GmailSearchState: Sendable, Hashable {
    case notAsked
    case searching
    case done(added: Int)
    case failed
}

public struct SearchWindowStatus: Sendable, Hashable {
    public let completeness: SearchCompletenessInfo
    public let gmail: GmailSearchState
    public let gmailAvailable: Bool

    public init(completeness: SearchCompletenessInfo = .complete, gmail: GmailSearchState = .notAsked,
                gmailAvailable: Bool = false) {
        self.completeness = completeness
        self.gmail = gmail
        self.gmailAvailable = gmailAvailable
    }
}

public struct SnippetVariableInfo: Sendable, Hashable, Codable {
    public var name: String
    public var defaultValue: String?

    public init(name: String, defaultValue: String? = nil) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

public struct SnippetInfo: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var account: AccountID?
    public var name: String
    public var shortcut: String?
    public var subject: String?
    public var bodyHTML: String
    public var variables: [SnippetVariableInfo]
    public var useCount: Int
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var attachments: [SnippetAttachmentInfo]

    public init(id: String = "", account: AccountID? = nil, name: String, shortcut: String? = nil,
                subject: String? = nil, bodyHTML: String, variables: [SnippetVariableInfo] = [], useCount: Int = 0,
                to: [EmailAddress] = [], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
                attachments: [SnippetAttachmentInfo] = []) {
        self.id = id
        self.account = account
        self.name = name
        self.shortcut = shortcut
        self.subject = subject
        self.bodyHTML = bodyHTML
        self.variables = variables
        self.useCount = useCount
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.attachments = attachments
    }

    public var isNew: Bool { id.isEmpty }

    public var addsRecipientsOrFiles: Bool { !(to.isEmpty && cc.isEmpty && bcc.isEmpty && attachments.isEmpty) }

    private enum CodingKeys: String, CodingKey {
        case id, account, name, shortcut, subject, bodyHTML, variables, useCount, to, cc, bcc, attachments
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), account: try c.decodeIfPresent(AccountID.self, forKey: .account),
                  name: try c.decode(String.self, forKey: .name), shortcut: try c.decodeIfPresent(String.self, forKey: .shortcut),
                  subject: try c.decodeIfPresent(String.self, forKey: .subject),
                  bodyHTML: try c.decode(String.self, forKey: .bodyHTML),
                  variables: try c.decodeIfPresent([SnippetVariableInfo].self, forKey: .variables) ?? [],
                  useCount: try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0,
                  to: try c.decodeIfPresent([EmailAddress].self, forKey: .to) ?? [],
                  cc: try c.decodeIfPresent([EmailAddress].self, forKey: .cc) ?? [],
                  bcc: try c.decodeIfPresent([EmailAddress].self, forKey: .bcc) ?? [],
                  attachments: try c.decodeIfPresent([SnippetAttachmentInfo].self, forKey: .attachments) ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(account, forKey: .account)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(shortcut, forKey: .shortcut)
        try c.encodeIfPresent(subject, forKey: .subject)
        try c.encode(bodyHTML, forKey: .bodyHTML)
        try c.encode(variables, forKey: .variables)
        try c.encode(useCount, forKey: .useCount)
        try c.encode(to, forKey: .to)
        try c.encode(cc, forKey: .cc)
        try c.encode(bcc, forKey: .bcc)
        try c.encode(attachments, forKey: .attachments)
    }
}

public struct SnippetAttachmentInfo: Sendable, Hashable, Codable {
    public var contentHash: String
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var fileURL: URL?

    public init(contentHash: String, filename: String, mimeType: String, size: Int, fileURL: URL? = nil) {
        self.contentHash = contentHash
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.fileURL = fileURL
    }
}

public enum SnippetAttachmentRules {
    public static let maxFileBytes = 10 * 1024 * 1024
    public static let maxTotalBytes = 25 * 1024 * 1024
    public static let maxFiles = 10
}

public struct FailedOperationInfo: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let account: AccountID
    public let kind: String
    public let threads: [ThreadKey]
    public let errorCode: String
    public let failedAt: Date

    public init(id: Int64, account: AccountID, kind: String, threads: [ThreadKey], errorCode: String, failedAt: Date) {
        self.id = id
        self.account = account
        self.kind = kind
        self.threads = threads
        self.errorCode = errorCode
        self.failedAt = failedAt
    }
}
