import Foundation
import OpenHumanCore

public enum MailCommand: Sendable, Hashable, Codable {
    case markDone([ThreadKey])
    case moveToInbox([ThreadKey])
    case trash([ThreadKey]), untrash([ThreadKey])
    case markRead([ThreadKey]), markUnread([ThreadKey])
    case star([ThreadKey]), unstar([ThreadKey])
    case markSpam([ThreadKey]), markNotSpam([ThreadKey])
    case modifyLabels([ThreadKey], add: [GmailLabelID], remove: [GmailLabelID])
    case snooze([ThreadKey], until: Date)
    case unsnooze([ThreadKey])
    case clearSnooze([ThreadKey])
    case setReminder(ThreadKey, dueAt: Date, kind: ReminderKind)
    case cancelReminder(ThreadKey)

    public var threads: [ThreadKey] {
        switch self {
        case .markDone(let keys), .moveToInbox(let keys), .trash(let keys), .untrash(let keys), .markRead(let keys),
             .markUnread(let keys), .star(let keys), .unstar(let keys), .markSpam(let keys), .markNotSpam(let keys),
             .modifyLabels(let keys, _, _), .snooze(let keys, _), .unsnooze(let keys), .clearSnooze(let keys):
            keys
        case .setReminder(let key, _, _), .cancelReminder(let key):
            [key]
        }
    }

    public var name: String {
        switch self {
        case .markDone: "markDone"
        case .moveToInbox: "moveToInbox"
        case .trash: "trash"
        case .untrash: "untrash"
        case .markRead: "markRead"
        case .markUnread: "markUnread"
        case .star: "star"
        case .unstar: "unstar"
        case .markSpam: "markSpam"
        case .markNotSpam: "markNotSpam"
        case .modifyLabels: "modifyLabels"
        case .snooze: "snooze"
        case .unsnooze: "unsnooze"
        case .clearSnooze: "clearSnooze"
        case .setReminder: "setReminder"
        case .cancelReminder: "cancelReminder"
        }
    }
}

public protocol MailCommanding: MailUndoing {
    func apply(_ command: MailCommand) async throws -> UndoToken

    func createDraft(_ input: DraftInput) async throws -> (key: DraftKey, version: Int)
    func updateDraft(_ key: DraftKey, _ fields: DraftFields, expectedVersion: Int?) async throws -> Int
    func flushDraft(_ key: DraftKey) async throws
    func discardDraft(_ key: DraftKey) async throws
    func setReviewState(_ key: DraftKey, _ state: DraftReview) async throws
    func resolveDraftConflict(_ key: DraftKey, _ resolution: DraftConflictResolution) async throws
    func send(_ key: DraftKey, undoWindow: Duration) async throws -> SendToken
    func cancelSend(_ token: SendToken) async throws -> Bool
    func sendNow(_ token: SendToken) async throws -> Bool
    func scheduleSend(_ key: DraftKey, at: Date) async throws
    func scheduleSend(_ key: DraftKey, at: Date, condition: SendLaterCondition) async throws
    func cancelScheduledSend(_ key: DraftKey) async throws
    func fetchDraftNow(_ account: AccountID, gmailDraftID: GmailDraftID) async throws -> DraftKey?
    func fetchThreadNow(_ account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadKey?

    func createLabel(_ account: AccountID, name: String, applyTo: [ThreadKey]) async throws -> UndoToken
    func upsertSnippet(_ snippet: SnippetInfo) async throws -> SnippetInfo
    func deleteSnippet(_ id: SnippetInfo.ID) async throws
    func recordSnippetUse(_ id: SnippetInfo.ID) async throws
    func storeSnippetAttachment(_ file: URL, mimeType: String) async throws -> SnippetAttachmentInfo
    func storeSnippetAttachment(data: Data, filename: String, mimeType: String) async throws -> SnippetAttachmentInfo
    func unsubscribe(_ key: MessageKey) async throws
    func upsertSplit(_ split: SplitDefinition) async throws -> SplitKey
    func deleteSplit(_ account: AccountID, _ key: SplitKey) async throws
    func reorderSplits(_ account: AccountID, _ order: [SplitKey]) async throws
    func dismissFailedOperation(_ id: FailedOperationInfo.ID) async throws
}

public enum SendLaterCondition: String, Sendable, Hashable, Codable, CaseIterable {
    case always
    case ifNoReply
}

extension MailCommanding {
    public func storeSnippetAttachment(_ file: URL, mimeType: String) async throws -> SnippetAttachmentInfo {
        throw MailPortError.unsupported("snippet attachments")
    }

    public func storeSnippetAttachment(data: Data, filename: String, mimeType: String) async throws -> SnippetAttachmentInfo {
        throw MailPortError.unsupported("snippet attachments")
    }
}

extension MailCommanding {
    public func scheduleSend(_ key: DraftKey, at: Date, condition: SendLaterCondition) async throws {
        guard condition == .always else { throw MailPortError.unsupported("send later only if no reply") }
        try await scheduleSend(key, at: at)
    }
}
