import Foundation
import OpenHumanCore
import OpenHumanStore

enum UndoSendRunner {
    @discardableResult
    static func reconcileAtLaunch(account: AccountID, store: MailStore, now: Date,
                                  emit: @Sendable (EngineEvent) -> Void) throws -> [DraftID] {
        var interrupted: [DraftID] = []
        for op in try store.dueItems(account: account, now: now).overdueUndoSends {
            guard case let .sendDraft(draftID) = op.payload else { continue }
            let receipt = SendReceipt(draftID: draftID, upsertOperationID: op.dependsOn, sendOperationID: op.id,
                                      sendAfter: op.notBefore)
            if try store.cancelSend(receipt) {
                interrupted.append(draftID)
                Log(.scheduler).notice("account \(account.rawValue): send of draft \(draftID.rawValue) was interrupted; back to a draft")
                emit(.sendInterrupted(draftID))
            }
        }
        return interrupted
    }
}
