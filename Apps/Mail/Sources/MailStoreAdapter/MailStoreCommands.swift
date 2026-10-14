import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore
import OpenHumanSync

public final class MailStoreCommands: MailCommanding, Sendable {
    private let engine: @Sendable () throws -> any MailEngineWriting
    private let safeMode: SafeModeInfo
    private let oneClick: (@Sendable (MessageKey) async throws -> Void)?

    init(engine: @escaping @Sendable () throws -> any MailEngineWriting, safeMode: SafeModeInfo,
         oneClick: (@Sendable (MessageKey) async throws -> Void)? = nil) {
        self.engine = engine
        self.safeMode = safeMode
        self.oneClick = oneClick
    }

    private func requireChanges(_ what: String) throws {
        guard safeMode != .readOnly else { throw Self.refusal(what, mode: safeMode) }
    }

    private func requireSending(_ what: String) throws {
        guard safeMode == .normal else { throw Self.refusal(what, mode: safeMode) }
    }

    private static func refusal(_ what: String, mode: SafeModeInfo) -> MailPortError {
        Log(.app).notice("write port: \(what) refused in safe mode \(String(describing: mode))")
        return .blockedBySafeMode
    }

    public func apply(_ command: MailCommand) async throws -> UndoToken {
        try requireChanges(command.name)
        let action = Self.action(command)
        let receipt = try await Self.mapping("the conversation") { try await engine().perform(action, origin: .app) }
        return try Self.token(receipt)
    }

    public func undo(_ token: UndoToken) async throws -> UndoToken? {
        try requireChanges("undo")
        let receipt = try Self.receipt(token)
        guard let redo = try await Self.mapping("the conversation", { try await engine().undo(receipt) }) else {
            return nil
        }
        return try Self.token(redo)
    }

    public func createLabel(_ account: AccountID, name: String, applyTo: [ThreadKey]) async throws -> UndoToken {
        try requireChanges("createLabel")
        let refs = applyTo.map(MailStoreAdapter.threadRef)
        let receipt = try await Self.mapping("the label") {
            try await engine().createLabel(account: account, name: name, applyTo: refs)
        }
        return try Self.token(receipt)
    }

    public func createDraft(_ input: DraftInput) async throws -> (key: DraftKey, version: Int) {
        try requireChanges("createDraft")
        let mode = MailStoreAdapter.composeMode(input.mode)
        let initial = input.content.map(MailStoreAdapter.content)
        let made = try await Self.mapping("the draft") {
            try await engine().newDraft(account: input.account, mode: mode, replyTo: input.replyTo?.gmailMessageID,
                                        origin: .user, initial: initial)
        }
        return (made.id, made.version)
    }

    public func updateDraft(_ key: DraftKey, _ fields: DraftFields, expectedVersion: Int?) async throws -> Int {
        try requireChanges("updateDraft")
        let content = MailStoreAdapter.content(fields)
        return try await Self.mapping("the draft") {
            try await engine().saveDraft(key, content: content, expectedVersion: expectedVersion)
        }
    }

    public func flushDraft(_ key: DraftKey) async throws {
        try requireChanges("flushDraft")
        try await Self.mapping("the draft") { try await engine().flushDraft(key) }
    }

    public func discardDraft(_ key: DraftKey) async throws {
        try requireChanges("discardDraft")
        try await Self.mapping("the draft") { try await engine().discardDraft(key) }
    }

    public func setReviewState(_ key: DraftKey, _ state: DraftReview) async throws {
        try requireChanges("setReviewState")
        let review: DraftReviewState = switch state {
        case .none: .none
        case .pending: .pending
        case .approved: .approved
        case .rejected: .rejected
        }
        try await Self.mapping("the draft") { try await engine().setReviewState(key, review) }
    }

    public func resolveDraftConflict(_ key: DraftKey, _ resolution: DraftConflictResolution) async throws {
        try requireChanges("resolveDraftConflict")
        let choice: DraftConflictChoice = resolution == .keepLocal ? .keepLocal : .takeRemote
        try await Self.mapping("the draft") { try await engine().resolveDraftConflict(key, keep: choice) }
    }

    public func send(_ key: DraftKey, undoWindow: Duration) async throws -> SendToken {
        try requireSending("send")
        let receipt = try await Self.mapping("the draft") {
            try await engine().send(key, authorization: .userConfirmed, undoWindow: undoWindow)
        }
        return SendToken(draft: key, sendAfter: receipt.sendAfter, payload: try JSONEncoder().encode(receipt))
    }

    public func cancelSend(_ token: SendToken) async throws -> Bool {
        try requireChanges("cancelSend")
        let receipt = try Self.sendReceipt(token)
        return try await Self.mapping("the draft") { try await engine().cancelSend(receipt) }
    }

    public func sendNow(_ token: SendToken) async throws -> Bool {
        try requireSending("sendNow")
        let receipt = try Self.sendReceipt(token)
        return try await Self.mapping("the draft") { try await engine().sendNow(receipt) }
    }

    public func scheduleSend(_ key: DraftKey, at: Date) async throws {
        try requireSending("scheduleSend")
        try await Self.mapping("the draft") { try await engine().scheduleSend(key, at: at) }
    }

    public func scheduleSend(_ key: DraftKey, at: Date, condition: SendLaterCondition) async throws {
        try requireSending("scheduleSend")
        try await Self.mapping("the draft") {
            try await engine().scheduleSend(key, at: at, onlyIfNoReply: condition == .ifNoReply)
        }
    }

    public func cancelScheduledSend(_ key: DraftKey) async throws {
        try requireChanges("cancelScheduledSend")
        try await Self.mapping("the draft") { try await engine().cancelScheduledSend(key) }
    }

    public func unsubscribe(_ key: MessageKey) async throws {
        try requireSending("unsubscribe")
        guard let oneClick else { throw MailPortError.unsupported("one-click unsubscribe") }
        try await oneClick(key)
    }

    public func fetchDraftNow(_ account: AccountID, gmailDraftID: GmailDraftID) async throws -> DraftKey? {
        try await Self.mapping("the draft") { try await engine().fetchDraft(account: account, gmailDraftID: gmailDraftID) }
    }

    public func fetchThreadNow(_ account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadKey? {
        let ref = try await Self.mapping("the conversation") {
            try await engine().fetchThread(account: account, gmailThreadID: gmailThreadID)
        }
        return ref.map(MailStoreAdapter.threadKey)
    }

    public func upsertSnippet(_ snippet: SnippetInfo) async throws -> SnippetInfo {
        try requireChanges("upsertSnippet")
        let item = MailStoreAdapter.snippetItem(snippet)
        return MailStoreAdapter.snippet(try await Self.mapping("the snippet") { try await engine().upsertSnippet(item) })
    }

    public func deleteSnippet(_ id: SnippetInfo.ID) async throws {
        try requireChanges("deleteSnippet")
        try await Self.mapping("the snippet") { try await engine().deleteSnippet(id: id) }
    }

    public func recordSnippetUse(_ id: SnippetInfo.ID) async throws {
        try requireChanges("recordSnippetUse")
        try await Self.mapping("the snippet") { try await engine().recordSnippetUse(id: id) }
    }

    public func storeSnippetAttachment(_ file: URL, mimeType: String) async throws -> SnippetAttachmentInfo {
        try requireChanges("storeSnippetAttachment")
        let writer = try self.engine()
        let stored = try await Self.mapping("the snippet file") { try await writer.storeSnippetAttachment(file: file, mimeType: mimeType) }
        return MailStoreAdapter.snippetAttachment(stored, fileURL: writer.snippetFileURL(stored))
    }

    public func storeSnippetAttachment(data: Data, filename: String, mimeType: String) async throws -> SnippetAttachmentInfo {
        try requireChanges("storeSnippetAttachment")
        let writer = try self.engine()
        let stored = try await Self.mapping("the snippet file") {
            try await writer.storeSnippetAttachment(data: data, filename: filename, mimeType: mimeType)
        }
        return MailStoreAdapter.snippetAttachment(stored, fileURL: writer.snippetFileURL(stored))
    }

    public func upsertSplit(_ split: SplitDefinition) async throws -> SplitKey {
        try requireChanges("upsertSplit")
        return try await Self.mapping("the split") {
            try await engine().upsertSplit(account: split.account, id: split.id, name: split.name,
                                           ruleText: split.ruleText, position: split.position, enabled: split.enabled)
        }
    }

    public func deleteSplit(_ account: AccountID, _ key: SplitKey) async throws {
        try requireChanges("deleteSplit")
        try await Self.mapping("the split") { try await engine().deleteSplit(key) }
    }

    public func reorderSplits(_ account: AccountID, _ order: [SplitKey]) async throws {
        try requireChanges("reorderSplits")
        try await Self.mapping("the split") { try await engine().reorderSplits(account: account, order) }
    }

    public func dismissFailedOperation(_ id: FailedOperationInfo.ID) async throws {
        try requireChanges("dismissFailedOperation")
        try await Self.mapping("the notice") { try await engine().dismissFailedOperation(OperationID(rawValue: id)) }
    }

    static func action(_ command: MailCommand) -> MailAction {
        let refs = { (keys: [ThreadKey]) in keys.map(MailStoreAdapter.threadRef) }
        switch command {
        case .markDone(let keys): return .archive(refs(keys))
        case .moveToInbox(let keys): return .moveToInbox(refs(keys))
        case .trash(let keys): return .trash(refs(keys))
        case .untrash(let keys): return .untrash(refs(keys))
        case .markRead(let keys): return .markRead(refs(keys))
        case .markUnread(let keys): return .markUnread(refs(keys))
        case .star(let keys): return .star(refs(keys))
        case .unstar(let keys): return .unstar(refs(keys))
        case .markSpam(let keys): return .markSpam(refs(keys))
        case .markNotSpam(let keys): return .markNotSpam(refs(keys))
        case .modifyLabels(let keys, let add, let remove): return .modifyLabels(refs(keys), add: add, remove: remove)
        case .snooze(let keys, let until): return .snooze(refs(keys), until: until)
        case .unsnooze(let keys): return .unsnooze(refs(keys))
        case .clearSnooze(let keys): return .clearSnooze(refs(keys))
        case .setReminder(let key, let dueAt, let kind):
            return .setReminder(MailStoreAdapter.threadRef(key), dueAt: dueAt,
                                condition: kind == .ifNoReply ? .ifNoReply : .always)
        case .cancelReminder(let key): return .cancelReminder(MailStoreAdapter.threadRef(key))
        }
    }

    static func token(_ receipt: ActionReceipt) throws -> UndoToken {
        UndoToken(payload: try JSONEncoder().encode(receipt),
                  changesNothing: receipt.operationIDs.isEmpty && receipt.undo == nil)
    }

    static func receipt(_ token: UndoToken) throws -> ActionReceipt {
        do { return try JSONDecoder().decode(ActionReceipt.self, from: token.payload) } catch {
            throw MailPortError.conflict("try again")
        }
    }

    static func sendReceipt(_ token: SendToken) throws -> SendReceipt {
        do { return try JSONDecoder().decode(SendReceipt.self, from: token.payload) } catch {
            throw MailPortError.conflict("try again")
        }
    }

    static func mapping<T>(_ what: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as MailPortError {
            throw error
        } catch let error as EngineError {
            switch error {
            case .blockedBySafeMode: throw MailPortError.blockedBySafeMode
            case .sendNotAllowed, .requiresApp: throw MailPortError.unavailable("Mail can't make changes")
            case .oauthClientMissing: throw MailPortError.unavailable("sign in again")
            }
        } catch let error as StoreError {
            switch error {
            case .notFound: throw MailPortError.notFound(what)
            case .conflict: throw MailPortError.conflict(what)
            case .reservedLabel(let name): throw MailPortError.reservedLabel(name)
            case .limitExceeded(let limit): throw MailPortError.limitExceeded(limit == "labels" ? "scheduled items" : limit)
            case .invalidQuery: throw MailPortError.invalidQuery("split rule")
            case .accountNotActive: throw MailPortError.unavailable("the account needs to sign in again")
            default: throw MailPortError.unavailable("\(what) couldn't be changed")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MailPortError.unavailable("Gmail couldn't be reached")
        }
    }
}

public protocol MailEngineWriting: Sendable {
    func perform(_ action: MailAction, origin: OperationOrigin) async throws -> ActionReceipt
    func undo(_ receipt: ActionReceipt) async throws -> ActionReceipt?
    func createLabel(account: AccountID, name: String, applyTo: [ThreadRef]) async throws -> ActionReceipt
    func newDraft(account: AccountID, mode: ComposeMode, replyTo: GmailMessageID?, origin: DraftOrigin,
                  initial: DraftContent?) async throws -> NewDraft
    func saveDraft(_ id: DraftID, content: DraftContent, expectedVersion: Int?) async throws -> Int
    func flushDraft(_ id: DraftID) async throws
    func discardDraft(_ id: DraftID) async throws
    func setReviewState(_ id: DraftID, _ state: DraftReviewState) async throws
    func resolveDraftConflict(_ id: DraftID, keep: DraftConflictChoice) async throws
    func send(_ id: DraftID, authorization: SendAuthorization, undoWindow: Duration?) async throws -> SendReceipt
    func cancelSend(_ receipt: SendReceipt) async throws -> Bool
    func sendNow(_ receipt: SendReceipt) async throws -> Bool
    func scheduleSend(_ id: DraftID, at: Date) async throws
    func scheduleSend(_ id: DraftID, at: Date, onlyIfNoReply: Bool) async throws
    func cancelScheduledSend(_ id: DraftID) async throws
    func fetchDraft(account: AccountID, gmailDraftID: GmailDraftID) async throws -> DraftID?
    func fetchThread(account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadRef?
    func upsertSnippet(_ snippet: SnippetItem) async throws -> SnippetItem
    func deleteSnippet(id: String) async throws
    func recordSnippetUse(id: String) async throws
    func storeSnippetAttachment(file: URL, mimeType: String) async throws -> SnippetAttachment
    func storeSnippetAttachment(data: Data, filename: String, mimeType: String) async throws -> SnippetAttachment
    func snippetFileURL(_ attachment: SnippetAttachment) -> URL?
    func upsertSplit(account: AccountID, id: SplitID?, name: String, ruleText: String, position: Int?,
                     enabled: Bool) async throws -> SplitID
    func deleteSplit(_ id: SplitID) async throws
    func reorderSplits(account: AccountID, _ ids: [SplitID]) async throws
    func dismissFailedOperation(_ id: OperationID) async throws
}

extension MailEngine: MailEngineWriting {
    public nonisolated func resolveDraftConflict(_ id: DraftID, keep: DraftConflictChoice) async throws {
        try store.resolveDraftConflict(id, keep: keep)
    }

    public nonisolated func dismissFailedOperation(_ id: OperationID) async throws {
        try store.dismissFailedOperation(id)
    }
}
