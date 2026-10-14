import Foundation
import OpenHumanCore
import OpenHumanStore

struct ReminderRunner: ScheduleRunner {
    let context: RunnerContext
    static let replyCheckLimit = 1_000
    private let log = Log(.scheduler)

    init(_ context: RunnerContext) { self.context = context }

    var kind: ScheduleKind { .reminder }

    func nextDue(account: AccountID, now: Date) async throws -> Date? {
        try context.store.nextDueTime(account: account, kinds: [.reminder])
    }

    func reconcile(account: AccountID, now: Date) async throws {
        let store = context.store
        for summary in try store.activeReminders(account: account, limit: Self.replyCheckLimit)
        where summary.reminder.condition == .ifNoReply && summary.reminder.dueAt > now {
            if try store.hasReplySince(summary.ref, anchor: nil) {
                _ = try store.fireReminder(summary.reminder.id, now: now, satisfied: true)
                log.info("account \(account.rawValue): reminder \(summary.reminder.id) satisfied by a reply")
            }
        }

        var due = try store.dueItems(account: account, now: now).remindersDue
        guard !due.isEmpty else { return }
        if due.contains(where: { $0.1.condition == .ifNoReply }), context.isReachable() {
            do {
                try await context.syncer.sync(reason: "reminder-reply-check")
                due = try store.dueItems(account: account, now: now).remindersDue
            } catch {
                log.notice("account \(account.rawValue): reply check sync failed (\(AccountSyncer.code(error))); deciding on cached mail")
            }
        }
        var queued = false
        for (ref, info) in due {
            let replied = info.condition == .ifNoReply ? try store.hasReplySince(ref, anchor: nil) : false
            let visible = replied ? false : try Self.hasVisibleMessage(ref, store: store)
            let receipt = try store.fireReminder(info.id, now: now, satisfied: replied)
            if let receipt, !receipt.operationIDs.isEmpty { queued = true }
            if receipt != nil || visible {
                log.info("account \(account.rawValue): reminder \(info.id) fired")
                context.emit(.reminderFired(ref, overdueBy: .elapsed(from: info.dueAt, to: now)))
            }
        }
        if queued { await context.pokeDrainer() }
    }

    static func hasVisibleMessage(_ ref: ThreadRef, store: MailStore) throws -> Bool {
        try store.threadDetail(ref.rowID)?.messages.contains { !$0.inTrash && !$0.inSpam && !$0.isDraft } ?? false
    }
}
