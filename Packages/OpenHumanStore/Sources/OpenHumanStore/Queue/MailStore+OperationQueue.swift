import Foundation
import GRDB
import OpenHumanCore

extension MailStore: OperationQueueStoring {
    public func claimReadyOperations(account: AccountID, now: Date, limit: Int, ownerID: String) throws -> [OperationItem] {
        try write { db in
            let t = Self.storeMillis(now)
            let orphans = try Int64.fetchAll(db, sql: """
                SELECT o.op_id FROM pending_operations o JOIN pending_operations d ON d.op_id = o.depends_on
                WHERE o.account_id = ? AND o.status = 'pending' AND d.status IN ('failed', 'cancelled')
                ORDER BY o.op_id
                """, arguments: [account.rawValue])
            for id in orphans {
                try Self.failPermanently(id, code: "dependency_failed", message: "the operation it depends on did not succeed",
                                         countsAttempt: false, in: db)
            }
            try Self.supersedeOlderDraftUploads(account: account.rawValue, in: db)
            try db.execute(sql: """
                UPDATE pending_operations SET claimed_at = ?
                WHERE account_id = ? AND kind = 'send_draft' AND status = 'pending' AND claimed_at IS NULL
                  AND not_before <= ?
                """, arguments: [t, account.rawValue, t])
            let ids = try Int64.fetchAll(db, sql: """
                SELECT o.op_id FROM pending_operations o LEFT JOIN pending_operations d ON d.op_id = o.depends_on
                WHERE o.account_id = ? AND o.status = 'pending' AND o.not_before <= ? AND o.next_retry_at <= ?
                  AND (o.depends_on IS NULL OR d.status = 'succeeded')
                  AND \(Self.notBehindAnOlderOp)
                ORDER BY o.op_id LIMIT ?
                """, arguments: [account.rawValue, t, t, max(limit, 0)])
            for id in ids {
                try db.execute(sql: """
                    UPDATE pending_operations
                    SET status = 'in_flight', claimed_by = ?, claimed_at = COALESCE(claimed_at, ?), updated_at = ?
                    WHERE op_id = ?
                    """, arguments: [ownerID, t, t, id])
            }
            return try ids.compactMap { try Self.operationItem(id: $0, in: db) }
        }
    }

    public func complete(_ id: OperationID, outcome: OperationOutcome) throws {
        let op = try requireLive(id)
        switch outcome {
        case let .labelCreated(label):
            guard op.kind == .createLabel else { throw Self.mismatch(op, outcome) }
            try upsertLabels([label], account: op.accountID, removeMissing: false)
        case let .sent(message):
            guard op.kind == .sendDraft else { throw Self.mismatch(op, outcome) }
            _ = try upsertSentCopy(message, account: op.accountID)
        default:
            break
        }
        let finishedDraft = try write { db -> String? in
            guard let op = try Self.operationItem(id: id.rawValue, in: db) else {
                throw StoreError.notFound("operation \(id.rawValue)")
            }
            guard op.status == .inFlight || op.status == .pending else {
                throw StoreError.conflict("operation \(id.rawValue) is already \(op.status.rawValue)")
            }
            var mids = Set<Int64>(), tids = Set<Int64>()
            var finished: String?
            var answered: [(mid: Int64, labels: Set<String>)] = []
            switch outcome {
            case .labelsApplied:
                // Fold the op's delta into server_label_ids so effective labels never revert while the history poll catches up
                guard [.modifyLabels, .trash, .untrash].contains(op.kind) else { throw Self.mismatch(op, outcome) }
                try Self.fold(op, returned: [], mids: &mids, tids: &tids, answered: &answered, in: db)
            case let .messagesReturned(messages):
                guard [.modifyLabels, .trash, .untrash].contains(op.kind) else { throw Self.mismatch(op, outcome) }
                try Self.fold(op, returned: messages, mids: &mids, tids: &tids, answered: &answered, in: db)
            case let .draftSaved(gmailDraftID, gmailMessageID, version):
                guard case let .upsertDraft(draftID, _) = op.payload else { throw Self.mismatch(op, outcome) }
                tids.formUnion(try Self.draftSaved(draftID, gmailDraftID: gmailDraftID, gmailMessageID: gmailMessageID,
                                                   version: version, origin: op.origin, in: db))
            case .draftDeleted:
                guard op.kind == .deleteDraft else { throw Self.mismatch(op, outcome) }
            case let .sent(message):
                guard case let .sendDraft(draftID) = op.payload else { throw Self.mismatch(op, outcome) }
                let tid = try Int64.fetchOne(db, sql: "SELECT tid FROM messages WHERE account_id = ? AND gmail_message_id = ?",
                                             arguments: [op.accountID.rawValue, message.gmailMessageID.rawValue])
                let old = try Int64.fetchOne(db, sql: "SELECT tid FROM drafts WHERE draft_uuid = ?", arguments: [draftID.rawValue])
                try db.execute(sql: """
                    UPDATE drafts SET state = 'sent', last_error = NULL, tid = COALESCE(?, tid),
                        gmail_thread_id = ?, updated_at = ? WHERE draft_uuid = ?
                    """, arguments: [tid, message.gmailThreadID.rawValue, nowMillis(), draftID.rawValue])
                for t in [tid, old].compactMap({ $0 }) { tids.insert(t) }
                finished = draftID.rawValue
            case .labelCreated:
                break
            }
            for r in try Self.linkedMessages(op: id.rawValue, in: db) { mids.insert(r.mid); tids.insert(r.tid) }
            try db.execute(sql: """
                UPDATE pending_operations SET status = 'succeeded', claimed_by = NULL, updated_at = ? WHERE op_id = ?
                """, arguments: [nowMillis(), id.rawValue])
            if EchoGuard.kinds.contains(op.kind) {
                for copy in answered {
                    try EchoGuard.snapshot(mid: copy.mid, account: op.accountID.rawValue, labels: copy.labels, in: db)
                }
            } else {
                try db.execute(sql: "DELETE FROM pending_op_messages WHERE op_id = ?", arguments: [id.rawValue])
            }
            try LabelOverlay.recompute(mids: mids, in: db)
            try ThreadAggregator.refresh(tids: tids, in: db)
            return finished
        }
        if let finishedDraft { removeDraftDirectory(finishedDraft) }
    }

    public func fail(_ id: OperationID, code: String, message: String, retryAt: Date?) throws {
        let removed = try write { db -> String? in
            if let retryAt {
                try db.execute(sql: """
                    UPDATE pending_operations
                    SET status = 'pending', attempts = attempts + 1, next_retry_at = ?, claimed_by = NULL,
                        last_error_code = ?, last_error_message = ?, updated_at = ?
                    WHERE op_id = ? AND status IN ('pending', 'in_flight')
                    """, arguments: [Self.storeMillis(retryAt), code, message, nowMillis(), id.rawValue])
                return nil
            }
            if Self.cancellingCodes.contains(code) {
                return try Self.cancel(id.rawValue, code: code, message: message, in: db)
            }
            try Self.failPermanently(id.rawValue, code: code, message: message, countsAttempt: true, in: db)
            return nil
        }
        if let removed { removeDraftDirectory(removed) }
    }

    public func release(_ id: OperationID, retryAt: Date) throws {
        try write { db in
            try db.execute(sql: """
                UPDATE pending_operations SET status = 'pending', next_retry_at = ?, claimed_by = NULL, updated_at = ?
                WHERE op_id = ? AND status = 'in_flight'
                """, arguments: [Self.storeMillis(retryAt), nowMillis(), id.rawValue])
        }
    }

    public func requeueStaleInFlight(account: AccountID, claimedBefore: Date) throws -> Int {
        let anyInFlight = try read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM pending_operations
                               WHERE account_id = ? AND status = 'in_flight' AND claimed_at < ?)
                """, arguments: [account.rawValue, Self.storeMillis(claimedBefore)]) ?? false
        }
        guard anyInFlight else { return 0 }
        return try write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT o.op_id, o.claimed_by, c.pid FROM pending_operations o
                LEFT JOIN change_feed c ON c.writer_id = o.claimed_by
                WHERE o.account_id = ? AND o.status = 'in_flight' AND o.claimed_at < ?
                ORDER BY o.op_id
                """, arguments: [account.rawValue, Self.storeMillis(claimedBefore)])
            var alive: [Int32: Bool] = [:]
            var requeued = 0
            for r in rows {
                if (r["claimed_by"] as String?) == writerID { continue }
                if let pid: Int32 = r["pid"] {
                    let live = alive[pid] ?? Self.processIsAlive(pid)
                    alive[pid] = live
                    if live { continue }
                }
                try db.execute(sql: """
                    UPDATE pending_operations SET status = 'pending', attempts = attempts + 1, claimed_by = NULL, updated_at = ?
                    WHERE op_id = ?
                    """, arguments: [nowMillis(), r["op_id"] as Int64])
                requeued += 1
            }
            return requeued
        }
    }

    public func nextWakeTime(account: AccountID) throws -> Date? {
        try read { db in
            let t = try Int64.fetchOne(db, sql: """
                SELECT MIN(MAX(o.not_before, o.next_retry_at))
                FROM pending_operations o LEFT JOIN pending_operations d ON d.op_id = o.depends_on
                WHERE o.account_id = ? AND o.status = 'pending'
                  AND (o.depends_on IS NULL OR d.status IN ('succeeded', 'failed', 'cancelled'))
                  AND \(Self.notBehindAnOlderOp)
                """, arguments: [account.rawValue])
            return t.map { Self.storeDate(millis: $0) }
        }
    }

    public func garbageCollectOperations(now: Date) throws {
        try write { db in
            let t = Self.storeMillis(now)
            try EchoGuard.expireAndRefresh(now: t, in: db)
            try db.execute(sql: """
                DELETE FROM pending_operations
                WHERE ((status IN ('succeeded', 'cancelled') AND updated_at < ?) OR (status = 'failed' AND updated_at < ?))
                  AND NOT EXISTS (SELECT 1 FROM pending_operations d
                                  WHERE d.depends_on = pending_operations.op_id AND d.status IN ('pending', 'in_flight'))
                """, arguments: [t - 3_600_000, t - 7 * 86_400_000])
            try db.execute(sql: """
                DELETE FROM reminders WHERE state <> 'active' AND MAX(set_at, due_at) < ?
                """, arguments: [t - 30 * 86_400_000])
        }
    }
}

extension MailStore {
    static let cancellingCodes: Set<String> = ["target_gone", "stale_schedule"]

    static let notBehindAnOlderOp = """
        NOT EXISTS (SELECT 1 FROM pending_op_messages mine
                    JOIN pending_op_messages theirs ON theirs.mid = mine.mid AND theirs.op_id < o.op_id
                    JOIN pending_operations older ON older.op_id = theirs.op_id AND older.status IN ('pending', 'in_flight')
                    WHERE mine.op_id = o.op_id)
        """

    func requireLive(_ id: OperationID) throws -> OperationItem {
        guard let op = try read({ db in try Self.operationItem(id: id.rawValue, in: db) }) else {
            throw StoreError.notFound("operation \(id.rawValue)")
        }
        guard op.status == .inFlight || op.status == .pending else {
            throw StoreError.conflict("operation \(id.rawValue) is already \(op.status.rawValue)")
        }
        return op
    }

    static func mismatch(_ op: OperationItem, _ outcome: OperationOutcome) -> StoreError {
        .conflict("\(String(describing: outcome).prefix { $0 != "(" }) does not fit a \(op.kind.rawValue) operation")
    }

    static func fold(_ op: OperationItem, returned: [MessageUpsert], mids: inout Set<Int64>, tids: inout Set<Int64>,
                     answered: inout [(mid: Int64, labels: Set<String>)], in db: Database) throws {
        let targets: [GmailMessageID]
        switch op.payload {
        case let .modifyLabels(ids, _, _, _), let .trash(ids), let .untrash(ids): targets = ids
        default: return
        }
        let now = nowMillis()
        for target in targets {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT mid, tid, server_label_ids FROM messages WHERE account_id = ? AND gmail_message_id = ?
                """, arguments: [op.accountID.rawValue, target.rawValue]) else { continue }
            let mid: Int64 = row["mid"]
            let folded = try LabelOverlay.fold(op.payload, into: row["server_label_ids"], account: op.accountID.rawValue, in: db)
            try db.execute(sql: "UPDATE messages SET server_label_ids = ?, updated_at = ? WHERE mid = ?",
                           arguments: [folded, now, mid])
            mids.insert(mid)
            tids.insert(row["tid"])
        }
        for message in returned {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT mid, tid, history_id FROM messages WHERE account_id = ? AND gmail_message_id = ?
                """, arguments: [op.accountID.rawValue, message.gmailMessageID.rawValue]) else { continue }
            let incoming = Int64(clamping: message.historyID.rawValue)
            guard incoming >= (row["history_id"] as Int64) else { continue }
            let labels = Set(message.labelIDs.map(\.rawValue))
            try db.execute(sql: "UPDATE messages SET server_label_ids = ?, history_id = ?, updated_at = ? WHERE mid = ?",
                           arguments: [Labels.join(labels), incoming, now, row["mid"] as Int64])
            mids.insert(row["mid"])
            tids.insert(row["tid"])
            answered.append((row["mid"], labels))
        }
    }

    static func draftSaved(_ id: DraftID, gmailDraftID: GmailDraftID, gmailMessageID: GmailMessageID, version: Int,
                           origin: OperationOrigin, in db: Database) throws -> Set<Int64> {
        guard let r = try Row.fetchOne(db, sql: "SELECT * FROM drafts WHERE draft_uuid = ?", arguments: [id.rawValue]) else {
            return []
        }
        let row = DraftRow(r)
        var tids = Set(try Int64.fetchAll(db, sql: """
            SELECT tid FROM drafts WHERE account_id = ? AND gmail_draft_id = ? AND draft_uuid <> ? AND tid IS NOT NULL
            """, arguments: [row.account, gmailDraftID.rawValue, row.uuid]))
        if let tid = row.tid { tids.insert(tid) }
        try db.execute(sql: """
            DELETE FROM drafts WHERE account_id = ? AND gmail_draft_id = ? AND draft_uuid <> ?
              AND local_version <= synced_version
            """, arguments: [row.account, gmailDraftID.rawValue, row.uuid])
        try db.execute(sql: "UPDATE drafts SET gmail_draft_id = NULL WHERE account_id = ? AND gmail_draft_id = ? AND draft_uuid <> ?",
                       arguments: [row.account, gmailDraftID.rawValue, row.uuid])
        let dropConflict = row.conflict?.gmailMessageID == gmailMessageID.rawValue
        try db.execute(sql: """
            UPDATE drafts SET gmail_draft_id = ?, gmail_message_id = ?, synced_version = MAX(synced_version, ?),
                remote_conflict_json = CASE WHEN ? THEN NULL ELSE remote_conflict_json END, updated_at = ?
            WHERE draft_uuid = ?
            """, arguments: [gmailDraftID.rawValue, gmailMessageID.rawValue, min(version, row.localVersion), dropConflict,
                             nowMillis(), row.uuid])
        if row.state == .discarded {
            _ = try OpWriter.insert(account: row.account, payload: .deleteDraft(draftID: id, gmailDraftID: gmailDraftID),
                                    origin: origin, coalesceKey: nil, in: db)
        }
        return tids
    }

    static func failPermanently(_ id: Int64, code: String, message: String, countsAttempt: Bool, in db: Database) throws {
        let linked = try linkedMessages(op: id, in: db)
        try db.execute(sql: """
            UPDATE pending_operations
            SET status = 'failed', attempts = attempts + ?, claimed_by = NULL, last_error_code = ?,
                last_error_message = ?, updated_at = ?
            WHERE op_id = ? AND status IN ('pending', 'in_flight')
            """, arguments: [countsAttempt ? 1 : 0, code, message, nowMillis(), id])
        guard db.changesCount == 1 else { return }
        try db.execute(sql: "DELETE FROM pending_op_messages WHERE op_id = ?", arguments: [id])
        if let op = try operationItem(id: id, in: db) {
            switch op.payload {
            case let .sendDraft(draft):
                try setDraftState(draft, to: .failed, from: [.sending], error: message, in: db)
            case let .upsertDraft(draft, _):
                try db.execute(sql: "UPDATE drafts SET last_error = ?, updated_at = ? WHERE draft_uuid = ?",
                               arguments: [message, nowMillis(), draft.rawValue])
            default:
                break
            }
        }
        try LabelOverlay.recompute(mids: Set(linked.map(\.mid)), in: db)
        try ThreadAggregator.refresh(tids: Set(linked.map(\.tid)), in: db)
        try failDependents(of: id, in: db)
    }

    @discardableResult
    static func cancel(_ id: Int64, code: String, message: String, in db: Database) throws -> String? {
        let linked = try linkedMessages(op: id, in: db)
        try db.execute(sql: """
            UPDATE pending_operations SET status = 'cancelled', claimed_by = NULL, last_error_code = ?,
                last_error_message = ?, updated_at = ?
            WHERE op_id = ? AND status IN ('pending', 'in_flight')
            """, arguments: [code, message, nowMillis(), id])
        guard db.changesCount == 1 else { return nil }
        try db.execute(sql: "DELETE FROM pending_op_messages WHERE op_id = ?", arguments: [id])
        var removed: String?
        if let op = try operationItem(id: id, in: db), case let .sendDraft(draft) = op.payload {
            if code == "target_gone" {
                try setDraftState(draft, to: .discarded, from: [.sending], error: nil, in: db)
                removed = draft.rawValue
            } else if code == "stale_schedule" {
                try setDraftState(draft, to: .scheduled, from: [.sending], error: nil, in: db)
            }
        }
        try LabelOverlay.recompute(mids: Set(linked.map(\.mid)), in: db)
        try ThreadAggregator.refresh(tids: Set(linked.map(\.tid)), in: db)
        try failDependents(of: id, in: db)
        return removed
    }

    static func failDependents(of id: Int64, in db: Database) throws {
        for dependent in try Int64.fetchAll(db, sql: """
            SELECT op_id FROM pending_operations WHERE depends_on = ? AND status = 'pending' ORDER BY op_id
            """, arguments: [id]) {
            try failPermanently(dependent, code: "dependency_failed", message: "the operation it depends on did not succeed",
                                countsAttempt: false, in: db)
        }
    }

    static func setDraftState(_ id: DraftID, to state: DraftState, from: Set<DraftState>, error: String?,
                              in db: Database) throws {
        guard let r = try Row.fetchOne(db, sql: "SELECT state, tid FROM drafts WHERE draft_uuid = ?", arguments: [id.rawValue]),
              let current = DraftState(rawValue: r["state"]), from.contains(current) else { return }
        try db.execute(sql: "UPDATE drafts SET state = ?, last_error = ?, updated_at = ? WHERE draft_uuid = ?",
                       arguments: [state.rawValue, error, nowMillis(), id.rawValue])
        if let tid: Int64 = r["tid"] { try ThreadAggregator.refresh(tids: [tid], in: db) }
    }

    static func supersedeOlderDraftUploads(account: Int64, in db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT op_id, payload_json FROM pending_operations
            WHERE account_id = ? AND kind = 'upsert_draft' AND status = 'pending' ORDER BY op_id
            """, arguments: [account])
        guard rows.count > 1 else { return }
        var newest: [String: Int64] = [:]
        var byDraft: [(op: Int64, draft: String)] = []
        for r in rows {
            guard case let .upsertDraft(draft, _) = try OperationPayloadCodec.decode(kind: .upsertDraft, json: r["payload_json"])
            else { continue }
            byDraft.append((r["op_id"], draft.rawValue))
            newest[draft.rawValue] = r["op_id"]
        }
        for entry in byDraft where newest[entry.draft] != entry.op {
            let dependents = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM pending_operations WHERE depends_on = ? AND status IN ('pending', 'in_flight')
                """, arguments: [entry.op]) ?? 0
            if dependents == 0 {
                try cancel(entry.op, code: "superseded", message: "a newer save of the draft is queued", in: db)
            }
        }
    }
}
