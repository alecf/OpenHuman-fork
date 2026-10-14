import Foundation

public enum GmailMethod: String, Sendable, CaseIterable, Hashable {
    case getProfile = "getProfile"
    case listSendAs = "settings.sendAs.list"
    case listLabels = "labels.list"
    case getLabel = "labels.get"
    case createLabel = "labels.create"
    case listThreads = "threads.list"
    case getThread = "threads.get"
    case trashThread = "threads.trash"
    case untrashThread = "threads.untrash"
    case listMessages = "messages.list"
    case getMessage = "messages.get"
    case getAttachment = "messages.attachments.get"
    case batchModify = "messages.batchModify"
    case modifyMessage = "messages.modify"
    case trashMessage = "messages.trash"
    case untrashMessage = "messages.untrash"
    case sendMessage = "messages.send"
    case insertMessage = "messages.insert"
    case listDrafts = "drafts.list"
    case getDraft = "drafts.get"
    case createDraft = "drafts.create"
    case updateDraft = "drafts.update"
    case deleteDraft = "drafts.delete"
    case sendDraft = "drafts.send"
    case listHistory = "history.list"

    public var isIdempotent: Bool {
        switch self {
        case .sendMessage, .sendDraft, .createDraft, .insertMessage: return false
        default: return true
        }
    }
}

public enum QuotaCost {
    public static func units(_ method: GmailMethod) -> Int {
        switch method {
        case .getProfile, .listSendAs, .listLabels, .getLabel: return 1
        case .createLabel: return 5
        case .listThreads, .untrashThread: return 10
        case .getThread: return 40
        case .trashThread: return 20
        case .listMessages, .modifyMessage, .untrashMessage: return 5
        case .getMessage, .getAttachment, .trashMessage: return 20
        case .batchModify: return 50
        case .sendMessage, .sendDraft: return 100
        case .insertMessage: return 25
        case .listDrafts: return 5
        case .getDraft: return 20
        case .createDraft, .deleteDraft: return 10
        case .updateDraft: return 15
        case .listHistory: return 2
        }
    }
}
