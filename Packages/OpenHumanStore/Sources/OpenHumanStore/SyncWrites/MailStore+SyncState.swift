import Foundation
import GRDB
import OpenHumanCore

extension MailStore {
    public func updateSyncState(account: AccountID, _ update: (inout SyncStateUpdate) -> Void) throws {
        var u = SyncStateUpdate()
        update(&u)
        if u.incrementFailures && u.consecutiveFailures != nil { throw StoreError.conflict("sync_state") }
        func ms(_ d: Date?) -> Int64? { d.map { Self.storeMillis($0) } }
        var sets: [String] = []
        var args: [DatabaseValue] = []
        func set(_ column: String, _ value: (any DatabaseValueConvertible)?, if present: Bool) {
            guard present else { return }
            sets.append("\(column) = ?")
            args.append(value?.databaseValue ?? .null)
        }
        set("phase", u.phase?.rawValue, if: u.phase != nil)
        set("history_id", u.historyID.map { Int64(clamping: $0.rawValue) }, if: u.historyID != nil)
        set("bootstrap_history_id", u.bootstrapHistoryID.map { Int64(clamping: $0.rawValue) }, if: u.bootstrapHistoryID != nil)
        set("backfill_oldest_at", ms(u.backfillOldestAt), if: u.backfillOldestAt != nil)
        set("backfill_complete", u.backfillComplete, if: u.backfillComplete != nil)
        set("body_backfill_complete", u.bodyBackfillComplete, if: u.bodyBackfillComplete != nil)
        set("labels_refreshed_at", ms(u.labelsRefreshedAt), if: u.labelsRefreshedAt != nil)
        set("drafts_refreshed_at", ms(u.draftsRefreshedAt), if: u.draftsRefreshedAt != nil)
        set("send_as_refreshed_at", ms(u.sendAsRefreshedAt), if: u.sendAsRefreshedAt != nil)
        set("last_incremental_at", ms(u.lastIncrementalAt), if: u.lastIncrementalAt != nil)
        set("last_success_at", ms(u.lastSuccessAt), if: u.lastSuccessAt != nil)
        set("last_attempt_at", ms(u.lastAttemptAt), if: u.lastAttemptAt != nil)
        set("consecutive_failures", u.consecutiveFailures.map { max($0, 0) }, if: u.consecutiveFailures != nil)
        let settingError = u.lastErrorCode != nil || u.lastErrorMessage != nil
        set("last_error_code", u.lastErrorCode, if: u.lastErrorCode != nil || (u.clearLastError && !settingError))
        set("last_error_message", u.lastErrorMessage.map(Self.redactAddresses),
            if: u.lastErrorMessage != nil || (u.clearLastError && !settingError))
        if u.incrementFailures { sets.append("consecutive_failures = consecutive_failures + 1") }
        sets.append("updated_at = ?")
        args.append(nowMillis().databaseValue)
        try write { db in
            try db.execute(sql: "UPDATE sync_state SET \(sets.joined(separator: ", ")) WHERE account_id = ?",
                           arguments: StatementArguments(args + [account.rawValue.databaseValue]))
            if db.changesCount == 0 { throw StoreError.notFound("sync_state \(account.rawValue)") }
            if u.historyID != nil { try EchoGuard.expireAndRefresh(now: nowMillis(), in: db) }
        }
    }

    public func beginFullResync(account: AccountID) throws -> Int {
        try write { db in
            try db.execute(sql: "UPDATE sync_state SET generation = generation + 1, updated_at = ? WHERE account_id = ?",
                           arguments: [nowMillis(), account.rawValue])
            guard let generation = try Int.fetchOne(db, sql: "SELECT generation FROM sync_state WHERE account_id = ?",
                                                    arguments: [account.rawValue]) else {
                throw StoreError.notFound("sync_state \(account.rawValue)")
            }
            return generation
        }
    }

    public func sweepGeneration(account: AccountID, olderThan: Int, newerThan: Date?) throws -> Int {
        var total = 0
        while true {
            let n = try write { db -> Int in
                var sql = "SELECT mid, tid FROM messages WHERE account_id = ? AND sync_generation < ?"
                var args: [DatabaseValue] = [account.rawValue.databaseValue, olderThan.databaseValue]
                if let newerThan {
                    sql += " AND internal_date > ?"
                    args.append(Self.storeMillis(newerThan).databaseValue)
                }
                sql += " ORDER BY mid LIMIT ?"
                args.append(Self.sweepChunk.databaseValue)
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                let mids = rows.map { $0["mid"] as Int64 }
                let ops = try OperationTargets.linkedOperations(mids: mids, in: db)
                for mid in mids { try db.execute(sql: "DELETE FROM messages WHERE mid = ?", arguments: [mid]) }
                try OperationTargets.cancelOrphans(ops, in: db)
                try ThreadAggregator.refresh(tids: Set(rows.map { $0["tid"] as Int64 }), in: db)
                return rows.count
            }
            total += n
            if n < Self.sweepChunk { return total }
        }
    }

    static let sweepChunk = 500

    public func appendSyncLog(_ entry: SyncLogEntry) throws {
        try write { db in
            try db.execute(sql: """
                INSERT INTO sync_log (account_id, started_at, finished_at, kind, outcome, quota_units, requests, added,
                                      changed, deleted, error_code, detail)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [entry.accountID.rawValue, Self.storeMillis(entry.startedAt),
                                 entry.finishedAt.map { Self.storeMillis($0) }, entry.kind, entry.outcome,
                                 entry.quotaUnits, entry.requests, entry.added, entry.changed, entry.deleted,
                                 entry.errorCode.map(Self.redactAddresses), entry.detail.map(Self.redactAddresses)])
            try db.execute(sql: """
                DELETE FROM sync_log WHERE account_id = ?1 AND log_id NOT IN (
                    SELECT log_id FROM sync_log WHERE account_id = ?1 ORDER BY started_at DESC, log_id DESC LIMIT 1000)
                """, arguments: [entry.accountID.rawValue])
        }
    }

    public func pruneTombstones(account: AccountID, olderThan: Date) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM deleted_messages WHERE account_id = ? AND deleted_at < ?",
                           arguments: [account.rawValue, Self.storeMillis(olderThan)])
        }
    }

    static func redactAddresses(_ text: String) -> String {
        guard text.contains("@") else { return text }
        var out = ""
        var token = ""
        func flush() {
            if let at = token.firstIndex(of: "@"), at != token.startIndex, token.index(after: at) != token.endIndex {
                out += "<address>"
            } else {
                out += token
            }
            token = ""
        }
        for c in text {
            if c.isWhitespace || c == "," || c == ";" { flush(); out.append(c) } else { token.append(c) }
        }
        flush()
        return out
    }
}
