import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore

extension MailStoreAdapter {
    public func failedOperations(_ account: AccountID?) -> AsyncThrowingStream<[FailedOperationInfo], Error> {
        guard safeModeValue != .readOnly else {
            return AsyncThrowingStream { continuation in
                continuation.yield([])
                continuation.finish()
            }
        }
        let store = self.store
        return Self.map(store.observeFailedOperations().values()) { items in
            items.filter { account == nil || $0.accountID == account }.map { Self.failure($0, store: store) }
        }
    }

    static func failure(_ item: OperationItem, store: any Store) -> FailedOperationInfo {
        FailedOperationInfo(id: item.id.rawValue, account: item.accountID, kind: failedKind(item.payload),
                            threads: threads(of: item.payload, account: item.accountID, store: store),
                            errorCode: item.lastErrorCode ?? "error", failedAt: item.updatedAt)
    }

    static func failedKind(_ payload: OperationPayload) -> String {
        switch payload {
        case let .modifyLabels(_, add, remove, addNames):
            let added = Set(add.map(\.rawValue))
            let removed = Set(remove.map(\.rawValue))
            if !addNames.isEmpty { return "modifyLabels" }
            if added.contains("SPAM") { return "markSpam" }
            if removed.contains("SPAM") { return "markNotSpam" }
            let only: (Set<String>, Set<String>) -> Bool = { add, remove in added == add && removed == remove }
            if only([], ["INBOX"]) { return "markDone" }
            if only(["INBOX"], []) { return "moveToInbox" }
            if only([], ["UNREAD"]) { return "markRead" }
            if only(["UNREAD"], []) { return "markUnread" }
            if only(["STARRED"], []) { return "star" }
            if only([], ["STARRED"]) { return "unstar" }
            return "modifyLabels"
        case .trash: return "trash"
        case .untrash: return "untrash"
        case .upsertDraft: return "saveDraft"
        case .deleteDraft: return "deleteDraft"
        case .sendDraft: return "sendDraft"
        case .createLabel: return "createLabel"
        }
    }

    static func threads(of payload: OperationPayload, account: AccountID, store: any Store) -> [ThreadKey] {
        let messages: [GmailMessageID]
        switch payload {
        case let .modifyLabels(ids, _, _, _), let .trash(ids), let .untrash(ids): messages = ids
        case .upsertDraft, .deleteDraft, .sendDraft, .createLabel: return []
        }
        guard let keyed = store as? MailStore else { return [] }
        var seen: Set<Int64> = []
        var keys: [ThreadKey] = []
        for id in messages {
            guard let message = try? store.message(account: account, gmailMessageID: id),
                  let key = try? keyed.messageKey(message.id), seen.insert(key.ref.rowID.rawValue).inserted else { continue }
            keys.append(threadKey(key.ref))
        }
        return keys
    }
}
