import Foundation
import MailFeatures
import MailModel
import OpenHumanStore
import OpenHumanSync

enum EngineNotices {
    static func notice(for event: EngineEvent) -> AppEngineNotice? {
        switch event {
        case .operationFailed(let item):
            guard item.kind != .sendDraft else { return nil }
            return .operationFailed(account: item.accountID, kind: item.kind.rawValue, code: item.lastErrorCode ?? "error")
        case .sendFailed(_, let code):
            return .sendFailed(code: code)
        case .sendInterrupted:
            return .sendInterrupted
        case .scheduledSendNeedsConfirmation:
            return .scheduledSendNeedsConfirmation
        case .scheduledSendCancelledByReply:
            return .scheduledSendCancelledByReply
        case .snoozeWoke(let ref, let overdue):
            return .snoozeWoke(key(ref), overdue: seconds(overdue))
        case .reminderFired(let ref, let overdue):
            return .reminderFired(key(ref), overdue: seconds(overdue))
        case .schedulerDegraded(let kind, _):
            return .schedulerDegraded(kind: kind.rawValue)
        case .accountNeedsReauth(let account):
            return .accountNeedsReauth(account)
        case .scheduleLabelBudget(let account, let count):
            return .scheduleLabelBudget(account: account, count: count)
        case .sent, .syncFailed, .initialSyncProgress, .ownershipChanged:
            return nil
        }
    }

    static func key(_ ref: ThreadRef) -> ThreadKey {
        ThreadKey(account: ref.accountID, rowID: ref.rowID.rawValue, gmailThreadID: ref.gmailThreadID)
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
