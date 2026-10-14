import Foundation
import OpenHumanCore

public struct ThreadRowID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}
public struct MessageRowID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}
public struct LabelRowID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}
public struct OperationID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

public struct ThreadRef: Hashable, Codable, Sendable {
    public var accountID: AccountID
    public var rowID: ThreadRowID
    public var gmailThreadID: GmailThreadID

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        accountID: AccountID,
        rowID: ThreadRowID,
        gmailThreadID: GmailThreadID
    ) {
        self.accountID = accountID
        self.rowID = rowID
        self.gmailThreadID = gmailThreadID
    }
    // end generated-init
}

public enum SystemMailbox: String, Codable, Sendable, CaseIterable {
    case inbox, starred, important, unread, sent, drafts, allMail, trash, spam, snoozed, scheduled, reminders
    case done
    case waiting
}

public enum MailboxView: Hashable, Codable, Sendable {
    case system(AccountID, SystemMailbox)
    case label(AccountID, GmailLabelID)
    case split(AccountID, SplitID)
    case splitOther(AccountID)
    case unified(SystemMailbox)
}

public struct ThreadCursor: Hashable, Codable, Sendable {
    public var sortAt: Int64
    public var tid: Int64
    public var perAccount: [AccountID: ThreadCursorPosition]?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        sortAt: Int64,
        tid: Int64,
        perAccount: [AccountID: ThreadCursorPosition]? = nil
    ) {
        self.sortAt = sortAt
        self.tid = tid
        self.perAccount = perAccount
    }
    // end generated-init
}
public struct ThreadCursorPosition: Hashable, Codable, Sendable {
    public var sortAt: Int64; public var tid: Int64

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        sortAt: Int64,
        tid: Int64
    ) {
        self.sortAt = sortAt
        self.tid = tid
    }
    // end generated-init
}
