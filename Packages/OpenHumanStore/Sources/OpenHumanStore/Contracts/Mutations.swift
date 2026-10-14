import Foundation
import OpenHumanCore

public enum MailAction: Hashable, Codable, Sendable {
    case archive([ThreadRef])
    case moveToInbox([ThreadRef])
    case trash([ThreadRef])
    case untrash([ThreadRef])
    case markRead([ThreadRef]), markUnread([ThreadRef])
    case star([ThreadRef]), unstar([ThreadRef])
    case markSpam([ThreadRef]), markNotSpam([ThreadRef])
    case modifyLabels([ThreadRef], add: [GmailLabelID], remove: [GmailLabelID])
    case modifyMessageLabels(AccountID, [GmailMessageID], add: [GmailLabelID], remove: [GmailLabelID])
    case snooze([ThreadRef], until: Date)
    case unsnooze([ThreadRef])
    case clearSnooze([ThreadRef])
    case setReminder(ThreadRef, dueAt: Date, condition: ReminderCondition)
    case cancelReminder(ThreadRef)
    case createLabel(AccountID, name: String, applyTo: [ThreadRef])
}

public struct ActionReceipt: Hashable, Codable, Sendable {
    public var operationIDs: [OperationID]
    public var undo: MailAction?
    public var exactUndo: MailAction?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        operationIDs: [OperationID],
        undo: MailAction? = nil,
        exactUndo: MailAction? = nil
    ) {
        self.operationIDs = operationIDs
        self.undo = undo
        self.exactUndo = exactUndo
    }
    // end generated-init
}

public protocol MailMutating: Sendable {
    func apply(_ action: MailAction, origin: OperationOrigin) throws -> ActionReceipt
    func undo(_ receipt: ActionReceipt, origin: OperationOrigin) throws -> ActionReceipt?

    func createDraft(account: AccountID, mode: ComposeMode, replyTo: GmailMessageID?,
                     content: DraftContent, origin: DraftOrigin, reviewState: DraftReviewState,
                     agentNote: String?, extraHeaders: [String: String]) throws -> DraftID
    func updateAgentDraft(_ id: DraftID, content: DraftContent, agentNote: String?) throws -> Int
    func updateDraft(_ id: DraftID, content: DraftContent, expectedVersion: Int?) throws -> Int
    func saveDraftRemotely(_ id: DraftID) throws -> OperationID
    func discardDraft(_ id: DraftID) throws -> OperationID?
    func setReviewState(_ id: DraftID, _ state: DraftReviewState) throws
    func send(_ id: DraftID, undoWindow: Duration, origin: OperationOrigin) throws -> SendReceipt
    func scheduleSend(_ id: DraftID, at: Date) throws
    func cancelScheduledSend(_ id: DraftID) throws
    func cancelSend(_ receipt: SendReceipt) throws -> Bool
    func sendNow(_ receipt: SendReceipt) throws -> Bool
    func resolveDraftConflict(_ id: DraftID, keep: DraftConflictChoice) throws

    func upsertSnippet(_ s: SnippetItem) throws
    func deleteSnippet(id: String) throws
    func recordSnippetUse(id: String) throws
    func upsertSplit(account: AccountID, id: SplitID?, name: String, ruleText: String, position: Int?, enabled: Bool) throws -> SplitID
    func deleteSplit(_ id: SplitID) throws
    func reorderSplits(account: AccountID, _ ids: [SplitID]) throws
    func dismissFailedOperation(_ id: OperationID) throws
}

public struct SendReceipt: Hashable, Codable, Sendable {
    public var draftID: DraftID; public var upsertOperationID: OperationID?
    public var sendOperationID: OperationID; public var sendAfter: Date

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        draftID: DraftID,
        upsertOperationID: OperationID? = nil,
        sendOperationID: OperationID,
        sendAfter: Date
    ) {
        self.draftID = draftID
        self.upsertOperationID = upsertOperationID
        self.sendOperationID = sendOperationID
        self.sendAfter = sendAfter
    }
    // end generated-init
}
public enum DraftConflictChoice: String, Codable, Sendable { case keepLocal, takeRemote }
public enum OperationOrigin: String, Codable, Sendable { case app, cli, scheduler, agent }
