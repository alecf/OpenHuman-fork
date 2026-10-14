import Foundation
import OpenHumanCore
import OpenHumanStore

struct SnoozeRunner: ScheduleRunner {
    let context: RunnerContext
    private let log = Log(.scheduler)

    init(_ context: RunnerContext) { self.context = context }

    var kind: ScheduleKind { .snooze }

    func nextDue(account: AccountID, now: Date) async throws -> Date? {
        try context.store.nextDueTime(account: account, kinds: [.snooze])
            .map { $0.addingTimeInterval(context.jitter.timeInterval) }
    }

    func reconcile(account: AccountID, now: Date) async throws {
        let cutoff = now.addingTimeInterval(-context.jitter.timeInterval)
        guard Self.hasWork(try context.store.dueItems(account: account, now: cutoff)) else { return }
        let guardian = ScheduleGuard(context)
        guard await guardian.historyCheck() else { return }
        let due = try context.store.dueItems(account: account, now: cutoff)
        var stopped = false
        var queued = false

        for (ref, info) in due.snoozesToWake {
            guard let name = info.labelName else { continue }
            let check = try await guardian.confirmSnooze(ref) { stamps in
                let dueNow = stamps.filter { $0.due <= now }
                return dueNow.contains { $0.name == name } ? dueNow : []
            }
            guard case let .confirmed(labels, messageIDs) = check else { stopped = true; continue }
            let receipt = try context.store.wakeSnooze(ref, confirmedLabels: labels, messageIDs: messageIDs, now: now)
            guard !receipt.operationIDs.isEmpty else { continue }
            queued = true
            log.info("account \(account.rawValue): snooze woke thread \(ref.rowID.rawValue)")
            context.emit(.snoozeWoke(ref, overdueBy: .elapsed(from: info.wakeAt ?? now, to: now)))
        }
        for (ref, _) in due.snoozesWokenByMail {
            let check = try await guardian.confirmSnooze(ref) { $0 }
            guard case let .confirmed(labels, messageIDs) = check else { stopped = true; continue }
            let receipt = try context.store.clearSnooze(ref, confirmedLabels: labels, messageIDs: messageIDs)
            queued = queued || !receipt.operationIDs.isEmpty
        }
        for (ref, _) in due.snoozesToNormalize {
            let check = try await guardian.confirmSnooze(ref) { $0.count > 1 ? $0 : [] }
            guard case let .confirmed(labels, messageIDs) = check, let keep = labels.first else { stopped = true; continue }
            let receipt = try context.store.normalizeSnooze(ref, keep: keep, remove: Array(labels.dropFirst()),
                                                            messageIDs: messageIDs)
            queued = queued || !receipt.operationIDs.isEmpty
        }
        if queued { await context.pokeDrainer() }
        if stopped {
            _ = await guardian.historyCheck()
        }
    }

    static func hasWork(_ due: DueItems) -> Bool {
        !due.snoozesToWake.isEmpty || !due.snoozesWokenByMail.isEmpty || !due.snoozesToNormalize.isEmpty
    }
}
