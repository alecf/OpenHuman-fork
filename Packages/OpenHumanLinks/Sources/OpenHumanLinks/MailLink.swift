import Foundation

public enum LinkGrammar {
    public static let version = 1
    public static let scheme = "openhuman"
    public static let maxURLBytes = 40 * 1024
    public static let maxReviewIDs = 50
    public static let maxRecipients = 50
    public static let maxSubjectCharacters = 998
    public static let maxBodyBytes = 32 * 1024
}

public enum MailLink: Equatable, Sendable {
    case thread(account: AccountRef, threadID: String)
    case draft(account: AccountRef, draftID: String)
    case review([DraftRef])
    case search(query: String, account: AccountRef?)
    case compose(ComposePrefill)
    case settings(SettingsLink)
}

public enum SettingsLink: Equatable, Sendable {
    case page(String)
    case aiPrompts(promptID: String?)
}

public struct AccountRef: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct DraftRef: Hashable, Sendable {
    public let account: AccountRef?
    public let draftID: String
    public init(account: AccountRef?, draftID: String) {
        self.account = account
        self.draftID = draftID
    }
}

public struct ComposePrefill: Equatable, Sendable {
    public var account: AccountRef?
    public var to: [String]
    public var cc: [String]
    public var subject: String?
    public var body: String?
    public var droppedBcc: Bool

    public init(account: AccountRef? = nil, to: [String] = [], cc: [String] = [], subject: String? = nil,
                body: String? = nil, droppedBcc: Bool = false) {
        self.account = account
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.droppedBcc = droppedBcc
    }
}

public enum MailLinkError: Error, Equatable, Sendable {
    case wrongScheme, unknownRoute, invalidID, tooLong, tooManyItems, invalidAddress, invalidEncoding
}
