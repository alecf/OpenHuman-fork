import Foundation
import OpenHumanCore

public struct ParticipantSummary: Hashable, Codable, Sendable {
    public var name: String?; public var email: String; public var isMe: Bool; public var hasUnread: Bool

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        name: String? = nil,
        email: String,
        isMe: Bool,
        hasUnread: Bool
    ) {
        self.name = name
        self.email = email
        self.isMe = isMe
        self.hasUnread = hasUnread
    }
    // end generated-init
}

public struct ThreadListItem: Identifiable, Hashable, Sendable {
    public var id: ThreadRowID
    public var ref: ThreadRef
    public var subject: String
    public var snippet: String
    public var participantsDisplay: String
    public var participants: [ParticipantSummary]
    public var messageCount: Int
    public var unreadCount: Int
    public var isUnread: Bool
    public var draftCount: Int
    public var attachmentCount: Int
    public var isStarred: Bool
    public var isImportant: Bool
    public var userLabelIDs: [LabelRowID]
    public var categoryLabelIDs: [LabelRowID] = []
    public var lastMessageAt: Date
    public var sortAt: Date
    public var snoozedUntil: Date?
    public var reminderAt: Date?
    public var scheduledSendAt: Date?
    public var hasPendingChanges: Bool
    public var importance: ThreadImportance = .normal
    public var splitChipIDs: [LabelRowID] = []

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: ThreadRowID,
        ref: ThreadRef,
        subject: String,
        snippet: String,
        participantsDisplay: String,
        participants: [ParticipantSummary],
        messageCount: Int,
        unreadCount: Int,
        isUnread: Bool,
        draftCount: Int,
        attachmentCount: Int,
        isStarred: Bool,
        isImportant: Bool,
        userLabelIDs: [LabelRowID],
        categoryLabelIDs: [LabelRowID] = [],
        lastMessageAt: Date,
        sortAt: Date,
        snoozedUntil: Date? = nil,
        reminderAt: Date? = nil,
        scheduledSendAt: Date? = nil,
        hasPendingChanges: Bool,
        importance: ThreadImportance = .normal,
        splitChipIDs: [LabelRowID] = []
    ) {
        self.id = id
        self.ref = ref
        self.subject = subject
        self.snippet = snippet
        self.participantsDisplay = participantsDisplay
        self.participants = participants
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.isUnread = isUnread
        self.draftCount = draftCount
        self.attachmentCount = attachmentCount
        self.isStarred = isStarred
        self.isImportant = isImportant
        self.userLabelIDs = userLabelIDs
        self.categoryLabelIDs = categoryLabelIDs
        self.lastMessageAt = lastMessageAt
        self.sortAt = sortAt
        self.snoozedUntil = snoozedUntil
        self.reminderAt = reminderAt
        self.scheduledSendAt = scheduledSendAt
        self.hasPendingChanges = hasPendingChanges
        self.importance = importance
        self.splitChipIDs = splitChipIDs
    }
    // end generated-init
}

public struct ThreadPage: Sendable, Hashable {
    public var items: [ThreadListItem]
    public var nextCursor: ThreadCursor?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        items: [ThreadListItem],
        nextCursor: ThreadCursor? = nil
    ) {
        self.items = items
        self.nextCursor = nextCursor
    }
    // end generated-init
}

public struct LabelItem: Identifiable, Hashable, Sendable {
    public var id: LabelRowID
    public var accountID: AccountID
    public var key: String
    public var kind: LabelKind
    public var name: String
    public var displayName: String
    public var colorBackground: String?
    public var colorText: String?
    public var isHidden: Bool
    public var position: Int
    public var totalThreads: Int
    public var unreadThreads: Int

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: LabelRowID,
        accountID: AccountID,
        key: String,
        kind: LabelKind,
        name: String,
        displayName: String,
        colorBackground: String? = nil,
        colorText: String? = nil,
        isHidden: Bool,
        position: Int,
        totalThreads: Int,
        unreadThreads: Int
    ) {
        self.id = id
        self.accountID = accountID
        self.key = key
        self.kind = kind
        self.name = name
        self.displayName = displayName
        self.colorBackground = colorBackground
        self.colorText = colorText
        self.isHidden = isHidden
        self.position = position
        self.totalThreads = totalThreads
        self.unreadThreads = unreadThreads
    }
    // end generated-init
}
public enum LabelKind: String, Codable, Sendable { case system, category, user, virtual, split }

public struct MailboxCounts: Hashable, Sendable {
    public var accountID: AccountID
    public var byLabel: [LabelRowID: LabelCount]
    public var inboxUnread: Int
    public var splitUnread: [SplitID: Int]
    public var draftsCount: Int
    public var pendingReviewCount: Int
    public var failedOperationCount: Int

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        accountID: AccountID,
        byLabel: [LabelRowID: LabelCount],
        inboxUnread: Int,
        splitUnread: [SplitID: Int],
        draftsCount: Int,
        pendingReviewCount: Int,
        failedOperationCount: Int
    ) {
        self.accountID = accountID
        self.byLabel = byLabel
        self.inboxUnread = inboxUnread
        self.splitUnread = splitUnread
        self.draftsCount = draftsCount
        self.pendingReviewCount = pendingReviewCount
        self.failedOperationCount = failedOperationCount
    }
    // end generated-init
}
public struct LabelCount: Hashable, Sendable {
    public var total: Int; public var unread: Int

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        total: Int,
        unread: Int
    ) {
        self.total = total
        self.unread = unread
    }
    // end generated-init
}

public enum BodyState: Int, Codable, Sendable { case none = 0, metadataOnly = 1, stored = 2, failed = 3 }

public struct AttachmentItem: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var messageRowID: MessageRowID
    public var partID: String
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var contentID: String?
    public var isInline: Bool
    public var localFileURL: URL?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: Int64,
        messageRowID: MessageRowID,
        partID: String,
        filename: String,
        mimeType: String,
        size: Int,
        contentID: String? = nil,
        isInline: Bool,
        localFileURL: URL? = nil
    ) {
        self.id = id
        self.messageRowID = messageRowID
        self.partID = partID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentID = contentID
        self.isInline = isInline
        self.localFileURL = localFileURL
    }
    // end generated-init
}

public struct MessageItem: Identifiable, Hashable, Sendable {
    public var id: MessageRowID
    public var gmailMessageID: GmailMessageID
    public var date: Date
    public var headerDate: Date?
    public var from: EmailAddress?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var subject: String
    public var snippet: String
    public var labelIDs: [GmailLabelID]
    public var isUnread: Bool
    public var isStarred: Bool
    public var isDraft: Bool
    public var isFromMe: Bool
    public var inTrash: Bool
    public var inSpam: Bool
    public var rfc822MessageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var listUnsubscribe: String?
    public var listUnsubscribePost: String?
    public var hasCalendarInvite: Bool
    public var bodyState: BodyState
    public var attachments: [AttachmentItem]

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: MessageRowID,
        gmailMessageID: GmailMessageID,
        date: Date,
        headerDate: Date? = nil,
        from: EmailAddress? = nil,
        to: [EmailAddress],
        cc: [EmailAddress],
        bcc: [EmailAddress],
        replyTo: [EmailAddress],
        subject: String,
        snippet: String,
        labelIDs: [GmailLabelID],
        isUnread: Bool,
        isStarred: Bool,
        isDraft: Bool,
        isFromMe: Bool,
        inTrash: Bool,
        inSpam: Bool,
        rfc822MessageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String],
        listUnsubscribe: String? = nil,
        listUnsubscribePost: String? = nil,
        hasCalendarInvite: Bool,
        bodyState: BodyState,
        attachments: [AttachmentItem]
    ) {
        self.id = id
        self.gmailMessageID = gmailMessageID
        self.date = date
        self.headerDate = headerDate
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.snippet = snippet
        self.labelIDs = labelIDs
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.isDraft = isDraft
        self.isFromMe = isFromMe
        self.inTrash = inTrash
        self.inSpam = inSpam
        self.rfc822MessageID = rfc822MessageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
        self.hasCalendarInvite = hasCalendarInvite
        self.bodyState = bodyState
        self.attachments = attachments
    }
    // end generated-init
}

public struct MessageBody: Hashable, Sendable {
    public var messageRowID: MessageRowID
    public var html: String?
    public var text: String?
    public var hasRemoteContent: Bool
    public var inlineParts: [String: AttachmentItem]
    public var decodeWarnings: [String]
    public var textFormat: BodyTextFormat = .fixed

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        messageRowID: MessageRowID,
        html: String? = nil,
        text: String? = nil,
        hasRemoteContent: Bool,
        inlineParts: [String: AttachmentItem],
        decodeWarnings: [String],
        textFormat: BodyTextFormat = .fixed
    ) {
        self.messageRowID = messageRowID
        self.html = html
        self.text = text
        self.hasRemoteContent = hasRemoteContent
        self.inlineParts = inlineParts
        self.decodeWarnings = decodeWarnings
        self.textFormat = textFormat
    }
    // end generated-init
}

public struct ThreadDetail: Hashable, Sendable {
    public var thread: ThreadListItem
    public var messages: [MessageItem]
    public var labels: [LabelItem]
    public var drafts: [DraftListItem]
    public var snooze: SnoozeInfo?
    public var reminder: ReminderInfo?
    public var hiddenMessageIDs: [MessageRowID] = []

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        thread: ThreadListItem,
        messages: [MessageItem],
        labels: [LabelItem],
        drafts: [DraftListItem],
        snooze: SnoozeInfo? = nil,
        reminder: ReminderInfo? = nil,
        hiddenMessageIDs: [MessageRowID] = []
    ) {
        self.thread = thread
        self.messages = messages
        self.labels = labels
        self.drafts = drafts
        self.snooze = snooze
        self.reminder = reminder
        self.hiddenMessageIDs = hiddenMessageIDs
    }
    // end generated-init
}

public struct SuperhumanReminderEmailItem: Hashable, Sendable {
    public var message: MessageRowID
    public var gmailMessageID: GmailMessageID
    public var thread: ThreadRef
    public var date: Date
    public var isInInbox: Bool
    public var isHidden: Bool
    public var match: SuperhumanReminderMatch
    public var subject: String
    public var targetInInbox: Bool

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        message: MessageRowID,
        gmailMessageID: GmailMessageID,
        thread: ThreadRef,
        date: Date,
        isInInbox: Bool,
        isHidden: Bool,
        match: SuperhumanReminderMatch,
        subject: String,
        targetInInbox: Bool
    ) {
        self.message = message
        self.gmailMessageID = gmailMessageID
        self.thread = thread
        self.date = date
        self.isInInbox = isInInbox
        self.isHidden = isHidden
        self.match = match
        self.subject = subject
        self.targetInInbox = targetInInbox
    }
    // end generated-init
}

public enum SuperhumanReminderMatch: Hashable, Sendable {
    case sameConversation
    case replyHeaders(target: ThreadRef)
    case unmatched
}

public struct SnoozeInfo: Hashable, Sendable {
    public var wakeAt: Date?
    public var labelName: String?
    public var stampLabelCount: Int

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        wakeAt: Date? = nil,
        labelName: String? = nil,
        stampLabelCount: Int
    ) {
        self.wakeAt = wakeAt
        self.labelName = labelName
        self.stampLabelCount = stampLabelCount
    }
    // end generated-init
}
public struct ReminderInfo: Hashable, Sendable {
    public var id: String; public var dueAt: Date; public var condition: ReminderCondition

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: String,
        dueAt: Date,
        condition: ReminderCondition
    ) {
        self.id = id
        self.dueAt = dueAt
        self.condition = condition
    }
    // end generated-init
}
public enum ReminderCondition: String, Codable, Sendable { case always, ifNoReply = "if_no_reply" }

public enum DraftOrigin: String, Codable, Sendable { case user, agent, cli }
public enum DraftReviewState: String, Codable, Sendable { case none, pending, approved, rejected }
public enum DraftState: String, Codable, Sendable { case editing, scheduled, sending, sent, failed, discarded }
public enum ComposeMode: String, Codable, Sendable { case new, reply, replyAll = "reply_all", forward }

public struct DraftAttachment: Hashable, Codable, Sendable {
    public var localPath: String?
    public var sourceAttachmentID: Int64?
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var contentID: String?
    public var isInline: Bool

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        localPath: String? = nil,
        sourceAttachmentID: Int64? = nil,
        filename: String,
        mimeType: String,
        size: Int,
        contentID: String? = nil,
        isInline: Bool
    ) {
        self.localPath = localPath
        self.sourceAttachmentID = sourceAttachmentID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentID = contentID
        self.isInline = isInline
    }
    // end generated-init
}

public struct DraftContent: Hashable, Codable, Sendable {
    public var from: EmailAddress?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var bodyHTML: String
    public var bodyText: String?
    public var attachments: [DraftAttachment]

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        from: EmailAddress? = nil,
        to: [EmailAddress],
        cc: [EmailAddress],
        bcc: [EmailAddress],
        subject: String,
        bodyHTML: String,
        bodyText: String? = nil,
        attachments: [DraftAttachment]
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyHTML = bodyHTML
        self.bodyText = bodyText
        self.attachments = attachments
    }
    // end generated-init
}

public struct DraftListItem: Identifiable, Hashable, Sendable {
    public var id: DraftID
    public var accountID: AccountID
    public var gmailDraftID: GmailDraftID?
    public var thread: ThreadRef?
    public var composeMode: ComposeMode
    public var replyToMessageID: GmailMessageID?
    public var content: DraftContent
    public var origin: DraftOrigin
    public var reviewState: DraftReviewState
    public var state: DraftState
    public var sendAt: Date?
    public var isDirty: Bool
    public var hasRemoteConflict: Bool
    public var agentNote: String?
    public var agentSnapshot: DraftContent?
    public var lastError: String?
    public var updatedAt: Date
    public var localVersion: Int = 0
    public var gmailMessageID: GmailMessageID? = nil
    public var gmailThreadID: GmailThreadID? = nil
    public var extraHeaders: [String: String] = [:]

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: DraftID,
        accountID: AccountID,
        gmailDraftID: GmailDraftID? = nil,
        thread: ThreadRef? = nil,
        composeMode: ComposeMode,
        replyToMessageID: GmailMessageID? = nil,
        content: DraftContent,
        origin: DraftOrigin,
        reviewState: DraftReviewState,
        state: DraftState,
        sendAt: Date? = nil,
        isDirty: Bool,
        hasRemoteConflict: Bool,
        agentNote: String? = nil,
        agentSnapshot: DraftContent? = nil,
        lastError: String? = nil,
        updatedAt: Date,
        localVersion: Int = 0,
        gmailMessageID: GmailMessageID? = nil,
        gmailThreadID: GmailThreadID? = nil,
        extraHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.accountID = accountID
        self.gmailDraftID = gmailDraftID
        self.thread = thread
        self.composeMode = composeMode
        self.replyToMessageID = replyToMessageID
        self.content = content
        self.origin = origin
        self.reviewState = reviewState
        self.state = state
        self.sendAt = sendAt
        self.isDirty = isDirty
        self.hasRemoteConflict = hasRemoteConflict
        self.agentNote = agentNote
        self.agentSnapshot = agentSnapshot
        self.lastError = lastError
        self.updatedAt = updatedAt
        self.localVersion = localVersion
        self.gmailMessageID = gmailMessageID
        self.gmailThreadID = gmailThreadID
        self.extraHeaders = extraHeaders
    }
    // end generated-init
}

public struct AccountItem: Identifiable, Hashable, Sendable {
    public var id: AccountID
    public var email: String
    public var displayName: String?
    public var alias: String?
    public var color: String?
    public var position: Int
    public var status: AccountStatus
    public var sendAs: [SendAsIdentity]
    public var grantedScopes: [String] = []

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: AccountID,
        email: String,
        displayName: String? = nil,
        alias: String? = nil,
        color: String? = nil,
        position: Int,
        status: AccountStatus,
        sendAs: [SendAsIdentity],
        grantedScopes: [String] = []
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.alias = alias
        self.color = color
        self.position = position
        self.status = status
        self.sendAs = sendAs
        self.grantedScopes = grantedScopes
    }
    // end generated-init
}
public enum AccountStatus: String, Codable, Sendable { case active, needsReauth = "needs_reauth", disabled, removing }
public struct SendAsIdentity: Hashable, Codable, Sendable {
    public var email: String; public var name: String?; public var isDefault: Bool
    public var isPrimary: Bool; public var signatureHTML: String?; public var replyTo: String?
    public var verificationStatus: String? = nil

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        email: String,
        name: String? = nil,
        isDefault: Bool,
        isPrimary: Bool,
        signatureHTML: String? = nil,
        replyTo: String? = nil,
        verificationStatus: String? = nil
    ) {
        self.email = email
        self.name = name
        self.isDefault = isDefault
        self.isPrimary = isPrimary
        self.signatureHTML = signatureHTML
        self.replyTo = replyTo
        self.verificationStatus = verificationStatus
    }
    // end generated-init
}

public struct ContactSuggestion: Hashable, Sendable {
    public var name: String?; public var email: String; public var score: Double

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        name: String? = nil,
        email: String,
        score: Double
    ) {
        self.name = name
        self.email = email
        self.score = score
    }
    // end generated-init
}

public struct SnippetItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String; public var accountID: AccountID?; public var name: String
    public var shortcut: String?; public var subject: String?; public var bodyHTML: String
    public var variables: [SnippetVariable]; public var useCount: Int
    public var to: [EmailAddress] = []; public var cc: [EmailAddress] = []; public var bcc: [EmailAddress] = []
    public var attachments: [SnippetAttachment] = []

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: String,
        accountID: AccountID? = nil,
        name: String,
        shortcut: String? = nil,
        subject: String? = nil,
        bodyHTML: String,
        variables: [SnippetVariable],
        useCount: Int,
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        attachments: [SnippetAttachment] = []
    ) {
        self.id = id
        self.accountID = accountID
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
    // end generated-init
}
public struct SnippetAttachment: Hashable, Codable, Sendable {
    public var contentHash: String
    public var filename: String
    public var mimeType: String
    public var size: Int

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        contentHash: String,
        filename: String,
        mimeType: String,
        size: Int
    ) {
        self.contentHash = contentHash
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
    }
    // end generated-init
}

public enum SnippetAttachmentLimits {
    public static let maxFileBytes = 10 * 1024 * 1024
    public static let maxTotalBytes = 25 * 1024 * 1024
    public static let maxFiles = 10
}

public struct SnippetVariable: Hashable, Codable, Sendable {
    public var name: String; public var defaultValue: String?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        name: String,
        defaultValue: String? = nil
    ) {
        self.name = name
        self.defaultValue = defaultValue
    }
    // end generated-init
}

public struct SplitItem: Identifiable, Hashable, Sendable {
    public var id: SplitID; public var accountID: AccountID; public var labelRowID: LabelRowID
    public var name: String; public var position: Int; public var ruleText: String
    public var rule: SplitRule; public var enabled: Bool; public var unreadThreads: Int; public var totalThreads: Int
    public var isImportanceSplit: Bool = false

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: SplitID,
        accountID: AccountID,
        labelRowID: LabelRowID,
        name: String,
        position: Int,
        ruleText: String,
        rule: SplitRule,
        enabled: Bool,
        unreadThreads: Int,
        totalThreads: Int,
        isImportanceSplit: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.labelRowID = labelRowID
        self.name = name
        self.position = position
        self.ruleText = ruleText
        self.rule = rule
        self.enabled = enabled
        self.unreadThreads = unreadThreads
        self.totalThreads = totalThreads
        self.isImportanceSplit = isImportanceSplit
    }
    // end generated-init
}

public struct SyncStatus: Hashable, Sendable {
    public var accountID: AccountID
    public var phase: SyncPhase
    public var historyID: HistoryID?
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    public var backfillOldest: Date?
    public var backfillComplete: Bool
    public var consecutiveFailures: Int
    public var lastError: String?
    public var owner: LeaseInfo?
    public var pendingOperations: Int
    public var failedOperations: Int
    public var generation: Int = 1

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        accountID: AccountID,
        phase: SyncPhase,
        historyID: HistoryID? = nil,
        lastSuccessAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        backfillOldest: Date? = nil,
        backfillComplete: Bool,
        consecutiveFailures: Int,
        lastError: String? = nil,
        owner: LeaseInfo? = nil,
        pendingOperations: Int,
        failedOperations: Int,
        generation: Int = 1
    ) {
        self.accountID = accountID
        self.phase = phase
        self.historyID = historyID
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.backfillOldest = backfillOldest
        self.backfillComplete = backfillComplete
        self.consecutiveFailures = consecutiveFailures
        self.lastError = lastError
        self.owner = owner
        self.pendingOperations = pendingOperations
        self.failedOperations = failedOperations
        self.generation = generation
    }
    // end generated-init
}
public enum SyncPhase: String, Codable, Sendable { case new, bootstrapping, inboxReady = "inbox_ready", backfilling, incremental, resyncRequired = "resync_required" }
public struct LeaseInfo: Hashable, Sendable {
    public var ownerID: String; public var kind: String; public var pid: Int32; public var heartbeatAt: Date; public var isLive: Bool

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        ownerID: String,
        kind: String,
        pid: Int32,
        heartbeatAt: Date,
        isLive: Bool
    ) {
        self.ownerID = ownerID
        self.kind = kind
        self.pid = pid
        self.heartbeatAt = heartbeatAt
        self.isLive = isLive
    }
    // end generated-init
}

public enum StoreError: Error, Equatable, Sendable {
    case notFound(String)
    case readOnly
    case busy
    case schemaTooNew(found: Int, supported: Int)
    case sqliteMissingFeature(String)
    case invalidQuery(String, position: Int?)
    case unsupportedView(String)
    case conflict(String)
    case accountNotActive(AccountID)
    case integrity(String)
    case reservedLabel(String)
    case limitExceeded(String)
}

public indirect enum SplitRule: Codable, Hashable, Sendable {
    case from(String)
    case to(String)
    case label(String)
    case category(String)
    case isImportant, isStarred, isUnread
    case hasAttachment, hasCalendarInvite
    case isEvent
    case list(String)
    case subjectContains(String)
    case fromMeOnly
    case and([SplitRule]), or([SplitRule]), not(SplitRule)
}
