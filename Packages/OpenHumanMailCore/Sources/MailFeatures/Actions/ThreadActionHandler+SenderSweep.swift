import Foundation
import MailActions
import MailModel
import OpenHumanCore

struct SenderSweep: Sendable {
    let address: String?
    let account: AccountID?
    let thread: ThreadKey?

    enum Scope: Sendable {
        case inbox
        case all
    }

    func trashable(_ rows: [ThreadRow]) -> [ThreadKey] {
        guard let sender = address?.lowercased() else { return [] }
        return rows.filter { row in
            !row.isStarred && row.userLabelIDs.isEmpty && row.snoozedUntil == nil && row.reminderAt == nil
                && row.draftCount == 0 && row.scheduledSendAt == nil
                && row.participants.allSatisfy { !$0.isMe && $0.email.lowercased() == sender }
        }.map(\.id)
    }

    var query: String? { query(.inbox) }

    func query(_ scope: Scope) -> String? {
        guard let address, !address.isEmpty, !address.contains("\"") else { return nil }
        switch scope {
        case .inbox: return "from:\"\(address)\" in:inbox"
        case .all: return "from:\"\(address)\""
        }
    }
}

extension ThreadActionHandler {
    static let sweepLimit = 500

    struct SweepPlan {
        var targets: [ThreadKey] = []
        var leftOut = 0
        var capped = false
    }

    func sweepTargets(_ sweep: SenderSweep, scope: SenderSweep.Scope) async -> [ThreadKey] {
        await sweepPlan(sweep, scope: scope).targets
    }

    func sweepPlan(_ sweep: SenderSweep, scope: SenderSweep.Scope) async -> SweepPlan {
        guard let environment else { return SweepPlan() }
        var plan = SweepPlan()
        if let query = sweep.query(scope), let account = sweep.account {
            do {
                for try await page in environment.data.search(query, accounts: [account], limit: Self.sweepLimit) {
                    let rows = page.hits.map(\.row)
                    plan.capped = rows.count >= Self.sweepLimit
                    plan.targets = scope == .all ? sweep.trashable(rows) : rows.map(\.id)
                    let taken = Set(plan.targets)
                    plan.leftOut = rows.count { !taken.contains($0.id) && $0.id != sweep.thread }
                    break
                }
            } catch {
                plan = SweepPlan()
            }
        }
        if let thread = sweep.thread, !plan.targets.contains(thread) { plan.targets.append(thread) }
        return plan
    }

    func sweepSender(_ sweep: SenderSweep, _ action: ActionID, scope: SenderSweep.Scope = .inbox,
                     host: (any ActionHost)?) async {
        guard let environment else { return }
        let targets = await sweepTargets(sweep, scope: scope)
        guard let first = targets.first else { return }
        var context = host?.actionContext() ?? ActionContext()
        context.account = sweep.account ?? first.account
        context.selection = targets
        context.focusedThread = first
        await environment.actions.run(action, source: .toast, host: host, context: context)
    }
}
