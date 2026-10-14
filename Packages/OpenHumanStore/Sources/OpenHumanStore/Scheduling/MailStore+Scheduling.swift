import Foundation
import GRDB
import OpenHumanCore

extension MailStore: SchedulingStoring {
    public func dueItems(account: AccountID, now: Date) throws -> DueItems {
        try read { db in
            let a = account.rawValue
            let t = Self.storeMillis(now)
            var wake: [(ThreadRef, SnoozeInfo)] = [], byMail: [(ThreadRef, SnoozeInfo)] = []
            var normalize: [(ThreadRef, SnoozeInfo)] = []
            for r in try Row.fetchAll(db, sql: """
                SELECT s.tid, s.gmail_thread_id, s.wake_at, s.label_name, s.stamp_label_count, t.in_inbox
                FROM snoozes s JOIN threads t ON t.tid = s.tid
                WHERE s.account_id = ? AND s.status = 'active' AND s.wake_at IS NOT NULL
                ORDER BY s.wake_at, s.tid
                """, arguments: [a]) {
                let wakeAt: Int64 = r["wake_at"]
                let item = (ScheduleRows.ref(account: a, tid: r["tid"], gmailThreadID: r["gmail_thread_id"]),
                            SnoozeInfo(wakeAt: ScheduleRows.date(wakeAt), labelName: r["label_name"],
                                       stampLabelCount: r["stamp_label_count"]))
                if r["in_inbox"] as Bool { byMail.append(item) }
                else if wakeAt <= t { wake.append(item) }
                else if (r["stamp_label_count"] as Int) > 1 { normalize.append(item) }
            }
            let reminders = try Row.fetchAll(db, sql: """
                SELECT reminder_id, tid, account_id, gmail_thread_id, due_at, condition FROM reminders
                WHERE account_id = ? AND state = 'active' AND due_at <= ? ORDER BY due_at, reminder_id
                """, arguments: [a, t]).map {
                (ScheduleRows.ref(account: a, tid: $0["tid"], gmailThreadID: $0["gmail_thread_id"]), ScheduleRows.reminderInfo($0))
            }
            let sending = try Self.draftsWithLiveSend(in: db)
            let sends = try Row.fetchAll(db, sql: """
                SELECT * FROM drafts
                WHERE account_id = ? AND state = 'scheduled' AND send_at <= ? AND local_version <= synced_version
                  AND gmail_draft_id IS NOT NULL
                ORDER BY send_at, draft_uuid
                """, arguments: [a, t]).filter { !sending.contains($0["draft_uuid"]) }.map(ScheduleRows.draftListItem)
            let undoSends = try Row.fetchAll(db, sql: """
                SELECT * FROM pending_operations
                WHERE account_id = ? AND kind = 'send_draft' AND status = 'pending' AND attempts = 0
                  AND claimed_at IS NULL AND not_before < ? AND origin <> 'scheduler'
                ORDER BY op_id
                """, arguments: [a, t - 3_600_000]).map(Self.operationItem)
            return DueItems(snoozesToWake: wake, snoozesWokenByMail: byMail, snoozesToNormalize: normalize,
                            remindersDue: reminders, scheduledSendsDue: sends, overdueUndoSends: undoSends)
        }
    }

    public func nextDueTime(account: AccountID, kinds: Set<ScheduleKind>) throws -> Date? {
        try read { db in
            let a = account.rawValue
            var times: [Int64] = []
            if kinds.contains(.reminder), let t = try Int64.fetchOne(db, sql: """
                SELECT MIN(due_at) FROM reminders WHERE account_id = ? AND state = 'active'
                """, arguments: [a]) { times.append(t) }
            if kinds.contains(.snooze), let t = try Int64.fetchOne(db, sql: """
                SELECT MIN(wake_at) FROM snoozes WHERE account_id = ? AND status = 'active'
                """, arguments: [a]) { times.append(t) }
            if kinds.contains(.sendLater), let t = try Int64.fetchOne(db, sql: """
                SELECT MIN(send_at) FROM drafts WHERE account_id = ? AND state = 'scheduled'
                  AND local_version <= synced_version AND gmail_draft_id IS NOT NULL
                """, arguments: [a]) { times.append(t) }
            return times.min().map(ScheduleRows.date)
        }
    }

    public func wakeSnooze(_ thread: ThreadRef, confirmedLabels: [String], messageIDs: [GmailMessageID],
                           now: Date) throws -> ActionReceipt {
        try write { db in
            let add = try Self.snoozeMarkUnread(in: db) ? ["INBOX", "UNREAD"] : ["INBOX"]
            return try Self.schedulerLabels(thread, removeNames: [OHGmailLabels.snoozed] + confirmedLabels, add: add,
                                            messageIDs: messageIDs, boostAt: Self.storeMillis(now), notBefore: Self.storeMillis(now), in: db)
        }
    }

    public func clearSnooze(_ thread: ThreadRef, confirmedLabels: [String], messageIDs: [GmailMessageID]) throws -> ActionReceipt {
        try write { db in
            try Self.schedulerLabels(thread, removeNames: [OHGmailLabels.snoozed] + confirmedLabels, add: [],
                                     messageIDs: messageIDs, boostAt: nil, notBefore: 0, in: db)
        }
    }

    public func normalizeSnooze(_ thread: ThreadRef, keep: String, remove: [String],
                                messageIDs: [GmailMessageID]) throws -> ActionReceipt {
        try write { db in
            try Self.schedulerLabels(thread, removeNames: remove.filter { $0 != keep }, add: [], messageIDs: messageIDs,
                                     boostAt: nil, notBefore: 0, in: db)
        }
    }

    public func markScheduledSendNeedsAttention(_ id: DraftID, reason: String) throws {
        try write { db in
            let text: String
            switch reason {
            case "missed": text = "scheduled time passed while Mail was closed"
            case ScheduleDerivation.unreadableScheduleError: text = "scheduled time unreadable (needs attention)"
            default: text = reason
            }
            guard let row = try Row.fetchOne(db, sql: "SELECT state, tid FROM drafts WHERE draft_uuid = ?",
                                             arguments: [id.rawValue]) else { throw StoreError.notFound("draft \(id.rawValue)") }
            guard ["scheduled", "failed"].contains(row["state"] as String) else { return }
            try db.execute(sql: "UPDATE drafts SET state = 'failed', last_error = ?, updated_at = ? WHERE draft_uuid = ?",
                           arguments: [text, nowMillis(), id.rawValue])
            if let tid: Int64 = row["tid"] { try ThreadAggregator.refresh(tids: [tid], in: db) }
        }
    }

    static func schedulerLabels(_ thread: ThreadRef, removeNames: [String], add: [String], messageIDs: [GmailMessageID],
                                boostAt: Int64?, notBefore: Int64, in db: Database) throws -> ActionReceipt {
        try requireWritableAccount(thread.accountID, in: db)
        let a = thread.accountID.rawValue
        let index = try LabelIndex.load(account: a, in: db)
        var remove: [String] = []
        for name in removeNames { if let key = index.resolve(name), !remove.contains(key) { remove.append(key) } }
        var seen = Set<String>()
        let ids = messageIDs.map(\.rawValue).filter { seen.insert($0).inserted }
        var targets: [OpTarget] = []
        for id in ids {
            if let r = try Row.fetchOne(db, sql: """
                SELECT mid, tid, label_ids FROM messages WHERE account_id = ? AND gmail_message_id = ? AND tid = ?
                """, arguments: [a, id, thread.rowID.rawValue]) {
                targets.append(OpTarget(mid: r["mid"], tid: r["tid"], gmailID: id, labels: Labels.split(r["label_ids"])))
            }
        }
        guard !targets.isEmpty, !remove.isEmpty,
              targets.contains(where: { !$0.labels.isDisjoint(with: remove) }) else { return ActionReceipt(operationIDs: []) }
        let op = try OpWriter.modifyLabels(account: a, targets: targets, add: add, remove: remove, origin: .scheduler,
                                           coalesce: false, notBefore: notBefore, in: db)
        if let boostAt { try boost(tids: [thread.rowID.rawValue], at: boostAt, in: db) }
        try LabelOverlay.recompute(mids: Set(targets.map(\.mid)), in: db)
        try ThreadAggregator.refresh(tids: [thread.rowID.rawValue], in: db)
        return ActionReceipt(operationIDs: [OperationID(rawValue: op)], undo: nil)
    }

    static func draftsWithLiveSend(in db: Database) throws -> Set<String> {
        var out = Set<String>()
        for r in try Row.fetchAll(db, sql: """
            SELECT payload_json FROM pending_operations WHERE kind = 'send_draft' AND status IN ('pending', 'in_flight')
            """) {
            if case let .sendDraft(draft) = try OperationPayloadCodec.decode(kind: .sendDraft, json: r["payload_json"]) {
                out.insert(draft.rawValue)
            }
        }
        return out
    }
}
