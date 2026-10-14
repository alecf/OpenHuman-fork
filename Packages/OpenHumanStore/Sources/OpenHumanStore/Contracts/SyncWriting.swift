import Foundation
import OpenHumanCore

public struct LabelUpsert: Sendable {
    public var gmailLabelID: GmailLabelID; public var name: String; public var type: String
    public var colorBackground: String?; public var colorText: String?
    public var labelListVisibility: String?; public var messageListVisibility: String?
    public var threadsTotal: Int?; public var threadsUnread: Int?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        gmailLabelID: GmailLabelID,
        name: String,
        type: String,
        colorBackground: String? = nil,
        colorText: String? = nil,
        labelListVisibility: String? = nil,
        messageListVisibility: String? = nil,
        threadsTotal: Int? = nil,
        threadsUnread: Int? = nil
    ) {
        self.gmailLabelID = gmailLabelID
        self.name = name
        self.type = type
        self.colorBackground = colorBackground
        self.colorText = colorText
        self.labelListVisibility = labelListVisibility
        self.messageListVisibility = messageListVisibility
        self.threadsTotal = threadsTotal
        self.threadsUnread = threadsUnread
    }
    // end generated-init
}

public struct MessageUpsert: Sendable {
    public var gmailMessageID: GmailMessageID
    public var gmailThreadID: GmailThreadID
    public var historyID: HistoryID
    public var internalDate: Date
    public var labelIDs: [GmailLabelID]
    public var snippet: String
    public var sizeEstimate: Int
    public var headers: MessageHeaderFields?
    public var body: MessageBodyUpsert?
    public var attachments: [AttachmentUpsert]?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        gmailMessageID: GmailMessageID,
        gmailThreadID: GmailThreadID,
        historyID: HistoryID,
        internalDate: Date,
        labelIDs: [GmailLabelID],
        snippet: String,
        sizeEstimate: Int,
        headers: MessageHeaderFields? = nil,
        body: MessageBodyUpsert? = nil,
        attachments: [AttachmentUpsert]? = nil
    ) {
        self.gmailMessageID = gmailMessageID
        self.gmailThreadID = gmailThreadID
        self.historyID = historyID
        self.internalDate = internalDate
        self.labelIDs = labelIDs
        self.snippet = snippet
        self.sizeEstimate = sizeEstimate
        self.headers = headers
        self.body = body
        self.attachments = attachments
    }
    // end generated-init
}

public struct MessageHeaderFields: Sendable {
    public var subject: String; public var from: EmailAddress?
    public var to: [EmailAddress]; public var cc: [EmailAddress]; public var bcc: [EmailAddress]
    public var replyTo: [EmailAddress]; public var date: Date?
    public var messageID: String?; public var inReplyTo: String?; public var references: [String]
    public var listID: String?; public var listUnsubscribe: String?; public var listUnsubscribePost: String?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        subject: String,
        from: EmailAddress? = nil,
        to: [EmailAddress],
        cc: [EmailAddress],
        bcc: [EmailAddress],
        replyTo: [EmailAddress],
        date: Date? = nil,
        messageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String],
        listID: String? = nil,
        listUnsubscribe: String? = nil,
        listUnsubscribePost: String? = nil
    ) {
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.date = date
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.listID = listID
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
    }
    // end generated-init
}

public enum BodyTextFormat: String, Hashable, Codable, Sendable {
    case fixed
    case flowed
    case flowedDelSp = "flowed-delsp"
}

public struct MessageBodyUpsert: Sendable {
    public var html: String?; public var text: String?
    public var hasCalendarInvite: Bool; public var decodeWarnings: [String]
    public var searchText: String
    public var textFormat: BodyTextFormat = .fixed

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        html: String? = nil,
        text: String? = nil,
        hasCalendarInvite: Bool,
        decodeWarnings: [String],
        searchText: String,
        textFormat: BodyTextFormat = .fixed
    ) {
        self.html = html
        self.text = text
        self.hasCalendarInvite = hasCalendarInvite
        self.decodeWarnings = decodeWarnings
        self.searchText = searchText
        self.textFormat = textFormat
    }
    // end generated-init
}

public struct AttachmentUpsert: Sendable {
    public var partID: String; public var gmailAttachmentID: String?; public var filename: String
    public var mimeType: String; public var size: Int; public var contentID: String?; public var isInline: Bool

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        partID: String,
        gmailAttachmentID: String? = nil,
        filename: String,
        mimeType: String,
        size: Int,
        contentID: String? = nil,
        isInline: Bool
    ) {
        self.partID = partID
        self.gmailAttachmentID = gmailAttachmentID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentID = contentID
        self.isInline = isInline
    }
    // end generated-init
}

public struct LabelDelta: Sendable {
    public var gmailMessageID: GmailMessageID
    public var historyID: HistoryID
    public var added: [GmailLabelID]
    public var removed: [GmailLabelID]
    public var fullSetIfKnown: [GmailLabelID]?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        gmailMessageID: GmailMessageID,
        historyID: HistoryID,
        added: [GmailLabelID],
        removed: [GmailLabelID],
        fullSetIfKnown: [GmailLabelID]? = nil
    ) {
        self.gmailMessageID = gmailMessageID
        self.historyID = historyID
        self.added = added
        self.removed = removed
        self.fullSetIfKnown = fullSetIfKnown
    }
    // end generated-init
}

public struct RemoteDraftUpsert: Sendable {
    public var gmailDraftID: GmailDraftID; public var gmailMessageID: GmailMessageID
    public var gmailThreadID: GmailThreadID; public var content: DraftContent
    public var extraHeaders: [String: String]

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        gmailDraftID: GmailDraftID,
        gmailMessageID: GmailMessageID,
        gmailThreadID: GmailThreadID,
        content: DraftContent,
        extraHeaders: [String: String]
    ) {
        self.gmailDraftID = gmailDraftID
        self.gmailMessageID = gmailMessageID
        self.gmailThreadID = gmailThreadID
        self.content = content
        self.extraHeaders = extraHeaders
    }
    // end generated-init
}

public struct UpsertResult: Sendable {
    public var inserted: Int; public var updated: Int; public var skippedStale: Int; public var skippedTombstoned: Int
    public var touchedThreads: Set<ThreadRowID>
    public var unknownLabelIDs: Set<GmailLabelID>

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        inserted: Int,
        updated: Int,
        skippedStale: Int,
        skippedTombstoned: Int,
        touchedThreads: Set<ThreadRowID>,
        unknownLabelIDs: Set<GmailLabelID>
    ) {
        self.inserted = inserted
        self.updated = updated
        self.skippedStale = skippedStale
        self.skippedTombstoned = skippedTombstoned
        self.touchedThreads = touchedThreads
        self.unknownLabelIDs = unknownLabelIDs
    }
    // end generated-init
}

public struct SyncStateUpdate: Sendable {
    public var phase: SyncPhase?
    public var historyID: HistoryID?
    public var bootstrapHistoryID: HistoryID?
    public var backfillOldestAt: Date?
    public var backfillComplete: Bool?
    public var bodyBackfillComplete: Bool?
    public var labelsRefreshedAt: Date?
    public var draftsRefreshedAt: Date?
    public var sendAsRefreshedAt: Date?
    public var lastIncrementalAt: Date?
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    public var consecutiveFailures: Int?
    public var lastErrorCode: String?
    public var lastErrorMessage: String?
    public var clearLastError: Bool = false
    public var incrementFailures: Bool = false

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        phase: SyncPhase? = nil,
        historyID: HistoryID? = nil,
        bootstrapHistoryID: HistoryID? = nil,
        backfillOldestAt: Date? = nil,
        backfillComplete: Bool? = nil,
        bodyBackfillComplete: Bool? = nil,
        labelsRefreshedAt: Date? = nil,
        draftsRefreshedAt: Date? = nil,
        sendAsRefreshedAt: Date? = nil,
        lastIncrementalAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        consecutiveFailures: Int? = nil,
        lastErrorCode: String? = nil,
        lastErrorMessage: String? = nil,
        clearLastError: Bool = false,
        incrementFailures: Bool = false
    ) {
        self.phase = phase
        self.historyID = historyID
        self.bootstrapHistoryID = bootstrapHistoryID
        self.backfillOldestAt = backfillOldestAt
        self.backfillComplete = backfillComplete
        self.bodyBackfillComplete = bodyBackfillComplete
        self.labelsRefreshedAt = labelsRefreshedAt
        self.draftsRefreshedAt = draftsRefreshedAt
        self.sendAsRefreshedAt = sendAsRefreshedAt
        self.lastIncrementalAt = lastIncrementalAt
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.consecutiveFailures = consecutiveFailures
        self.lastErrorCode = lastErrorCode
        self.lastErrorMessage = lastErrorMessage
        self.clearLastError = clearLastError
        self.incrementFailures = incrementFailures
    }
    // end generated-init
}

public struct SyncLogEntry: Sendable {
    public var accountID: AccountID
    public var startedAt: Date
    public var finishedAt: Date?
    public var kind: String
    public var outcome: String?
    public var quotaUnits: Int = 0
    public var requests: Int = 0
    public var added: Int = 0
    public var changed: Int = 0
    public var deleted: Int = 0
    public var errorCode: String?
    public var detail: String?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        accountID: AccountID,
        startedAt: Date,
        finishedAt: Date? = nil,
        kind: String,
        outcome: String? = nil,
        quotaUnits: Int = 0,
        requests: Int = 0,
        added: Int = 0,
        changed: Int = 0,
        deleted: Int = 0,
        errorCode: String? = nil,
        detail: String? = nil
    ) {
        self.accountID = accountID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.kind = kind
        self.outcome = outcome
        self.quotaUnits = quotaUnits
        self.requests = requests
        self.added = added
        self.changed = changed
        self.deleted = deleted
        self.errorCode = errorCode
        self.detail = detail
    }
    // end generated-init
}

public struct BodyCounts: Hashable, Sendable {
    public var stored: Int
    public var pending: Int
    public var failed: Int
    public init(stored: Int = 0, pending: Int = 0, failed: Int = 0) {
        self.stored = stored
        self.pending = pending
        self.failed = failed
    }
}

public protocol SyncWriting: Sendable {
    func upsertLabels(_ labels: [LabelUpsert], account: AccountID, removeMissing: Bool) throws
    func upsertMessages(_ messages: [MessageUpsert], account: AccountID, generation: Int) throws -> UpsertResult
    func applyLabelDeltas(_ deltas: [LabelDelta], account: AccountID) throws -> UpsertResult
    func deleteMessages(_ ids: [GmailMessageID], account: AccountID, historyID: HistoryID) throws -> UpsertResult
    func storeBodies(_ bodies: [(GmailMessageID, MessageBodyUpsert, [AttachmentUpsert])], account: AccountID) throws
    func markBodyFailed(_ id: GmailMessageID, account: AccountID, reason: String) throws
    func messagesNeedingBodies(account: AccountID, newerThan: Date, limit: Int) throws -> [GmailMessageID]
    func messagesNeedingInviteCheck(account: AccountID, limit: Int) throws -> [GmailMessageID]
    func bodyCounts(account: AccountID) throws -> BodyCounts
    func knownMessageIDs(account: AccountID, among: [GmailMessageID]) throws -> Set<GmailMessageID>
    func threadsNeedingFetch(account: AccountID, stubs: [(GmailThreadID, HistoryID)]) throws -> [GmailThreadID]
    func inboxThreads(account: AccountID, labelled label: GmailLabelID) throws -> [ThreadRef]
    func reconcileRemoteDrafts(_ drafts: [RemoteDraftUpsert], account: AccountID, complete: Bool) throws
    func setAttachmentDownloaded(aid: Int64, relativePath: String) throws
    func updateSyncState(account: AccountID, _ update: (inout SyncStateUpdate) -> Void) throws
    func beginFullResync(account: AccountID) throws -> Int
    func sweepGeneration(account: AccountID, olderThan: Int, newerThan: Date?) throws -> Int
    func updateSendAs(account: AccountID, identities: [SendAsIdentity]) throws
    func appendSyncLog(_ entry: SyncLogEntry) throws
    func pruneTombstones(account: AccountID, olderThan: Date) throws
}
