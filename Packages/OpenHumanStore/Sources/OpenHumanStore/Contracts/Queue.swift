import Foundation
import OpenHumanCore

public struct OperationItem: Identifiable, Hashable, Sendable {
    public var id: OperationID; public var accountID: AccountID; public var kind: OperationKind
    public var payload: OperationPayload; public var status: OperationStatus; public var attempts: Int
    public var notBefore: Date; public var nextRetryAt: Date; public var dependsOn: OperationID?
    public var coalesceKey: String?; public var origin: OperationOrigin
    public var lastErrorCode: String?; public var lastErrorMessage: String?
    public var createdAt: Date; public var updatedAt: Date

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: OperationID,
        accountID: AccountID,
        kind: OperationKind,
        payload: OperationPayload,
        status: OperationStatus,
        attempts: Int,
        notBefore: Date,
        nextRetryAt: Date,
        dependsOn: OperationID? = nil,
        coalesceKey: String? = nil,
        origin: OperationOrigin,
        lastErrorCode: String? = nil,
        lastErrorMessage: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.kind = kind
        self.payload = payload
        self.status = status
        self.attempts = attempts
        self.notBefore = notBefore
        self.nextRetryAt = nextRetryAt
        self.dependsOn = dependsOn
        self.coalesceKey = coalesceKey
        self.origin = origin
        self.lastErrorCode = lastErrorCode
        self.lastErrorMessage = lastErrorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    // end generated-init
}
public enum OperationKind: String, Codable, Sendable { case modifyLabels = "modify_labels", trash, untrash, upsertDraft = "upsert_draft", deleteDraft = "delete_draft", sendDraft = "send_draft", createLabel = "create_label" }
public enum OperationStatus: String, Codable, Sendable { case pending, inFlight = "in_flight", succeeded, failed, cancelled }

public enum OperationPayload: Hashable, Codable, Sendable {
    case modifyLabels(ids: [GmailMessageID], add: [GmailLabelID], remove: [GmailLabelID], addNames: [String])
    case trash(ids: [GmailMessageID])
    case untrash(ids: [GmailMessageID])
    case upsertDraft(draftID: DraftID, version: Int)
    case deleteDraft(draftID: DraftID, gmailDraftID: GmailDraftID?)
    case sendDraft(draftID: DraftID)
    case createLabel(name: String)
}

public enum OperationOutcome: Sendable {
    case labelsApplied
    case messagesReturned([MessageUpsert])
    case draftSaved(gmailDraftID: GmailDraftID, gmailMessageID: GmailMessageID, version: Int)
    case draftDeleted
    case sent(MessageUpsert)
    case labelCreated(LabelUpsert)
}

public protocol OperationQueueStoring: Sendable {
    func claimReadyOperations(account: AccountID, now: Date, limit: Int, ownerID: String) throws -> [OperationItem]
    func complete(_ id: OperationID, outcome: OperationOutcome) throws
    func fail(_ id: OperationID, code: String, message: String, retryAt: Date?) throws
    func release(_ id: OperationID, retryAt: Date) throws
    func requeueStaleInFlight(account: AccountID, claimedBefore: Date) throws -> Int
    func nextWakeTime(account: AccountID) throws -> Date?
    func garbageCollectOperations(now: Date) throws
}
