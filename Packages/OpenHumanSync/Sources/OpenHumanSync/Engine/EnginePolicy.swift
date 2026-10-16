import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

enum EnginePolicy {
    static func checkMailWrite(role: EngineRole, what: String) throws {
        if role == .readOnly { throw EngineError.requiresApp("\(what) on a read-only engine") }
    }

    static func checkLocalWrite(role: EngineRole, what: String) throws {
        if role == .readOnly { throw EngineError.requiresApp("\(what) on a read-only engine") }
    }

    static func checkSend(role: EngineRole, what: String) throws {
        guard role == .app else { throw EngineError.sendNotAllowed }
    }

    static func checkNetwork(role: EngineRole, what: String) throws {
        guard role == .app else { throw EngineError.requiresApp(what) }
    }

    static func grantAllowsWrites(_ account: AccountItem) -> Bool {
        account.grantedScopes.contains(GmailScope.modify)
    }

    static func runsDrainer(account: AccountItem) -> Bool {
        grantAllowsWrites(account) && (account.status == .active || account.status == .needsReauth)
    }

    static func schedulerKinds(configured: Set<ScheduleKind>, account: AccountItem) -> Set<ScheduleKind> {
        runsDrainer(account: account) ? configured : []
    }

    static func settingKey(_ kind: ScheduleKind) -> SettingKey<Bool> {
        switch kind {
        case .reminder: return .schedulerRemindersEnabled
        case .snooze: return .schedulerSnoozeEnabled
        case .sendLater: return .schedulerSendLaterEnabled
        }
    }

    static func accounts(in action: MailAction) -> Set<AccountID> {
        switch action {
        case let .archive(refs), let .moveToInbox(refs), let .trash(refs), let .untrash(refs), let .markRead(refs),
             let .markUnread(refs), let .star(refs), let .unstar(refs), let .markSpam(refs), let .markNotSpam(refs),
             let .modifyLabels(refs, _, _), let .snooze(refs, _), let .unsnooze(refs), let .clearSnooze(refs):
            return Set(refs.map(\.accountID))
        case let .modifyMessageLabels(account, _, _, _), let .createLabel(account, _, _):
            return [account]
        case let .setReminder(ref, _, _), let .cancelReminder(ref):
            return [ref.accountID]
        }
    }
}
