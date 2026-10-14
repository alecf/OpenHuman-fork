import Foundation
import MailModel
import OpenHumanCore

extension ComposeManager {
    func setAutoReminder(of session: ComposeSession, draft key: DraftKey) async {
        defer { forgetSendReminder(key) }
        let sentAt = timing.now()
        let rule = await SentMailReminderRule.load(from: environment.settings)
        guard rule.enabled, session.pendingReminder == nil else { return }
        switch rule.scope {
        case .off:
            return
        case .needsFollowUp:
            let followUps = environment.followUps
            followUps.calendar = calendar
            await followUps.sendCommitted(session, draft: key, rule: rule, sentAt: sentAt)
        case .externalRecipients:
            let recipients = session.allRecipients.map(\.email)
            guard let due = rule.dueDate(sentAt: sentAt, recipients: recipients,
                                         myAddresses: session.account.myAddresses, calendar: calendar) else { return }
            session.pendingReminder = ComposeSession.PendingReminder(dueAt: due, kind: .ifNoReply)
            await setPendingReminder(of: session, draft: key)
        }
    }
}
