import Foundation
import OpenHumanCore

public typealias DraftKey = DraftID
public typealias SplitKey = SplitID

public struct ThreadKey: Hashable, Sendable, Codable {
    public let account: AccountID
    public let rowID: Int64
    public let gmailThreadID: GmailThreadID

    public init(account: AccountID, rowID: Int64, gmailThreadID: GmailThreadID) {
        self.account = account
        self.rowID = rowID
        self.gmailThreadID = gmailThreadID
    }

    public static func == (lhs: ThreadKey, rhs: ThreadKey) -> Bool {
        lhs.account == rhs.account && lhs.rowID == rhs.rowID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(account)
        hasher.combine(rowID)
    }
}

public struct MessageKey: Hashable, Sendable, Codable {
    public let account: AccountID
    public let rowID: Int64
    public let gmailMessageID: GmailMessageID

    public init(account: AccountID, rowID: Int64, gmailMessageID: GmailMessageID) {
        self.account = account
        self.rowID = rowID
        self.gmailMessageID = gmailMessageID
    }

    public static func == (lhs: MessageKey, rhs: MessageKey) -> Bool {
        lhs.account == rhs.account && lhs.rowID == rhs.rowID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(account)
        hasher.combine(rowID)
    }
}

public enum AccountHealth: Sendable, Hashable { case active, needsSignIn, disabled, removing }

public struct Account: Identifiable, Sendable, Hashable {
    public let id: AccountID
    public let email: String
    public let displayName: String?
    public let alias: String?
    public let health: AccountHealth
    public let sendAs: [SenderIdentity]

    public init(id: AccountID, email: String, displayName: String?, alias: String?, health: AccountHealth,
                sendAs: [SenderIdentity] = []) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.alias = alias
        self.health = health
        self.sendAs = sendAs
    }
}

public struct SenderIdentity: Sendable, Hashable, Codable {
    public let email: String
    public let name: String?
    public let isDefault: Bool
    public let isPrimary: Bool
    public let signatureHTML: String?
    public let replyTo: String?
    public let needsVerification: Bool

    public init(email: String, name: String? = nil, isDefault: Bool, isPrimary: Bool, signatureHTML: String? = nil,
                replyTo: String? = nil, needsVerification: Bool = false) {
        self.email = email
        self.name = name
        self.isDefault = isDefault
        self.isPrimary = isPrimary
        self.signatureHTML = signatureHTML
        self.replyTo = replyTo
        self.needsVerification = needsVerification
    }

    private enum CodingKeys: String, CodingKey {
        case email, name, isDefault, isPrimary, signatureHTML, replyTo, needsVerification
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decode(String.self, forKey: .email)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        isDefault = try c.decode(Bool.self, forKey: .isDefault)
        isPrimary = try c.decode(Bool.self, forKey: .isPrimary)
        signatureHTML = try c.decodeIfPresent(String.self, forKey: .signatureHTML)
        replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
        needsVerification = try c.decodeIfPresent(Bool.self, forKey: .needsVerification) ?? false
    }
}

public struct Participant: Sendable, Hashable {
    public let name: String?
    public let email: String
    public let isMe: Bool
    public let hasUnread: Bool

    public init(name: String?, email: String, isMe: Bool, hasUnread: Bool) {
        self.name = name
        self.email = email
        self.isMe = isMe
        self.hasUnread = hasUnread
    }
}

public struct ThreadRow: Identifiable, Sendable, Hashable {
    public let id: ThreadKey
    public let subject: String
    public let snippet: String
    public let participantsDisplay: String
    public let participants: [Participant]
    public let messageCount: Int
    public let unreadCount: Int
    public let draftCount: Int
    public let attachmentCount: Int
    public let isUnread: Bool
    public let isStarred: Bool
    public let isImportant: Bool
    public let userLabelIDs: [Int64]
    public let lastMessageAt: Date
    public let sortAt: Date
    public let snoozedUntil: Date?
    public let reminderAt: Date?
    public let scheduledSendAt: Date?
    public let hasPendingChanges: Bool
    public let categoryLabelIDs: [Int64]
    public let searchMatch: SearchMatchKind?
    public let returnedByReminder: Bool
    // Mail's own placement in the Important tab; isImportant is Gmail's mark
    public let isPlacedImportant: Bool

    public init(id: ThreadKey, subject: String, snippet: String, participantsDisplay: String,
                participants: [Participant], messageCount: Int, unreadCount: Int, draftCount: Int,
                attachmentCount: Int, isUnread: Bool, isStarred: Bool, isImportant: Bool, userLabelIDs: [Int64],
                lastMessageAt: Date, sortAt: Date, snoozedUntil: Date? = nil, reminderAt: Date? = nil,
                scheduledSendAt: Date? = nil, hasPendingChanges: Bool = false, categoryLabelIDs: [Int64] = [],
                searchMatch: SearchMatchKind? = nil, returnedByReminder: Bool = false, isPlacedImportant: Bool = false) {
        self.id = id
        self.subject = subject
        self.snippet = snippet
        self.participantsDisplay = participantsDisplay
        self.participants = participants
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.draftCount = draftCount
        self.attachmentCount = attachmentCount
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.isImportant = isImportant
        self.userLabelIDs = userLabelIDs
        self.lastMessageAt = lastMessageAt
        self.sortAt = sortAt
        self.snoozedUntil = snoozedUntil
        self.reminderAt = reminderAt
        self.scheduledSendAt = scheduledSendAt
        self.hasPendingChanges = hasPendingChanges
        self.categoryLabelIDs = categoryLabelIDs
        self.searchMatch = searchMatch
        self.returnedByReminder = returnedByReminder
        self.isPlacedImportant = isPlacedImportant
    }
}

public struct ThreadListWindow: Sendable, Equatable {
    public let rows: [ThreadRow]
    public let hasMore: Bool
    public let totalCount: Int
    public let search: SearchWindowStatus?

    public init(rows: [ThreadRow], hasMore: Bool, totalCount: Int, search: SearchWindowStatus? = nil) {
        self.rows = rows
        self.hasMore = hasMore
        self.totalCount = totalCount
        self.search = search
    }
}

public struct AttachmentInfo: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let filename: String
    public let mimeType: String
    public let size: Int
    public let contentID: String?
    public let isInline: Bool

    public init(id: Int64, filename: String, mimeType: String, size: Int, contentID: String?, isInline: Bool) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentID = contentID
        self.isInline = isInline
    }
}

public struct MessageSummary: Sendable, Hashable, Identifiable {
    public let id: MessageKey
    public let from: EmailAddress?
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let bcc: [EmailAddress]
    public let date: Date
    public let snippet: String
    public let isUnread: Bool
    public let attachments: [AttachmentInfo]
    public let hasCalendarInvite: Bool

    public init(id: MessageKey, from: EmailAddress?, to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress],
                date: Date, snippet: String, isUnread: Bool, attachments: [AttachmentInfo],
                hasCalendarInvite: Bool = false) {
        self.id = id
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.date = date
        self.snippet = snippet
        self.isUnread = isUnread
        self.attachments = attachments
        self.hasCalendarInvite = hasCalendarInvite
    }
}

public struct ConversationDetail: Sendable, Hashable {
    public let id: ThreadKey
    public let subject: String
    public let messages: [MessageSummary]
    public let drafts: [DraftSummary]
    public let userLabelIDs: [Int64]
    public let snooze: SnoozeState?
    public let reminder: ReminderItem?
    public let isStarred: Bool
    public let returnedByReminder: Bool

    public init(id: ThreadKey, subject: String, messages: [MessageSummary], drafts: [DraftSummary] = [],
                userLabelIDs: [Int64] = [], snooze: SnoozeState? = nil, reminder: ReminderItem? = nil,
                isStarred: Bool = false, returnedByReminder: Bool = false) {
        self.id = id
        self.subject = subject
        self.messages = messages
        self.drafts = drafts
        self.userLabelIDs = userLabelIDs
        self.snooze = snooze
        self.reminder = reminder
        self.isStarred = isStarred
        self.returnedByReminder = returnedByReminder
    }
}

public struct MessageContent: Sendable, Equatable {
    public let html: String?
    public let text: String?
    public let textFormat: MessageTextFormat

    public init(html: String?, text: String?, textFormat: MessageTextFormat = .fixed) {
        self.html = html
        self.text = text
        self.textFormat = textFormat
    }
}

public enum MessageTextFormat: Sendable, Hashable, Codable {
    case fixed
    case flowed(delSp: Bool)
}

public enum BodyLoadState: Sendable, Equatable {
    case fetching
    case available(MessageContent)
    case failed(String)
}

public enum SystemFolder: String, Sendable, Hashable, Codable, CaseIterable {
    case inbox, starred, important, unread, sent, drafts, allMail, trash, spam, snoozed, scheduled, reminders
    case done
    case waiting
}

public enum MailLocation: Hashable, Sendable, Codable {
    case split(SplitKey)
    case splitOther
    case system(SystemFolder)
    case label(GmailLabelID)
    case reviewQueue([DraftKey]?)
    case search(String)

    public var sortsAscending: Bool {
        switch self {
        case .system(.snoozed), .system(.scheduled), .system(.reminders), .system(.waiting): true
        default: false
        }
    }
}
