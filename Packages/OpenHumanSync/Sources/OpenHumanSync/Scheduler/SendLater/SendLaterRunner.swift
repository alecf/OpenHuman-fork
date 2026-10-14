import Foundation
import OpenHumanCore
import OpenHumanStore

struct SendLaterRunner: ScheduleRunner {
    let context: RunnerContext
    static let missedAfter: Duration = .seconds(24 * 3_600)
    static let attemptsPerDraft = 2
    private let log = Log(.scheduler)

    init(_ context: RunnerContext) { self.context = context }

    var kind: ScheduleKind { .sendLater }

    func nextDue(account: AccountID, now: Date) async throws -> Date? {
        try context.store.nextDueTime(account: account, kinds: [.sendLater])
            .map { $0.addingTimeInterval(context.jitter.timeInterval) }
    }

    func reconcile(account: AccountID, now: Date) async throws {
        let store = context.store
        let cutoff = now.addingTimeInterval(-context.jitter.timeInterval)
        var candidates: [DraftID] = []
        for draft in try store.dueItems(account: account, now: cutoff).scheduledSendsDue {
            if let reason = Self.localVerdict(draft, now: now) {
                try store.markScheduledSendNeedsAttention(draft.id, reason: reason)
                log.notice("account \(account.rawValue): scheduled send \(draft.id.rawValue) needs attention (\(reason))")
                context.emit(.scheduledSendNeedsConfirmation(draft.id))
            } else {
                candidates.append(draft.id)
            }
        }
        guard !candidates.isEmpty else { return }
        let guardian = ScheduleGuard(context)
        guard await guardian.historyCheck() else { return }

        var queued = false
        for id in candidates {
            attempts: for _ in 0..<Self.attemptsPerDraft {
                guard let draft = try store.dueItems(account: account, now: cutoff).scheduledSendsDue
                    .first(where: { $0.id == id }), Self.localVerdict(draft, now: now) == nil else { break }
                switch try await guardian.confirmScheduledSend(draft) {
                case .proceed:
                    break
                case .stop:
                    continue attempts
                case .needsAttention(let reason):
                    try store.markScheduledSendNeedsAttention(id, reason: reason)
                    log.notice("account \(account.rawValue): scheduled send \(id.rawValue) needs attention (\(reason))")
                    context.emit(.scheduledSendNeedsConfirmation(id))
                    break attempts
                }
                switch try store.scheduledSendHasReply(draft) {
                case false?:
                    break
                case true?:
                    try store.cancelScheduledSend(id)
                    log.notice("account \(account.rawValue): scheduled send \(id.rawValue) cancelled: a reply came first")
                    context.emit(.scheduledSendCancelledByReply(id))
                    break attempts
                case nil:
                    let reason = "unknown send condition"
                    try store.markScheduledSendNeedsAttention(id, reason: reason)
                    log.notice("account \(account.rawValue): scheduled send \(id.rawValue) needs attention (\(reason))")
                    context.emit(.scheduledSendNeedsConfirmation(id))
                    break attempts
                }
                _ = try store.send(id, undoWindow: .zero, origin: .scheduler)
                log.info("account \(account.rawValue): scheduled send \(id.rawValue) queued")
                queued = true
                break
            }
        }
        if queued { await context.pokeDrainer() }
    }

    static func localVerdict(_ draft: DraftListItem, now: Date) -> String? {
        guard draft.origin == .user || draft.reviewState == .approved else { return "needs review" }
        if let sendAt = draft.sendAt, now.timeIntervalSince(sendAt) >= missedAfter.timeInterval { return "missed" }
        return nil
    }
}
