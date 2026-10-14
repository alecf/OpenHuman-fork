import Foundation
import GRDB
import OpenHumanCore

extension MailStore {
    public func deleteMessages(_ ids: [GmailMessageID], account: AccountID, historyID: HistoryID) throws -> UpsertResult {
        try write { db in
            try requireAccount(account, in: db)
            let h = Int64(clamping: historyID.rawValue)
            let now = nowMillis()
            var tids = Set<Int64>()
            var mids: [Int64] = []
            for id in Set(ids).sorted(by: { $0.rawValue < $1.rawValue }) {
                try db.cached("""
                    INSERT INTO deleted_messages (account_id, gmail_message_id, history_id, deleted_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT (account_id, gmail_message_id) DO UPDATE SET
                        history_id = max(history_id, excluded.history_id), deleted_at = excluded.deleted_at
                    """).execute(arguments: [account.rawValue, id.rawValue, h, now])
                guard let row = try Row.fetchOne(db.cached("""
                    SELECT mid, tid FROM messages WHERE account_id = ? AND gmail_message_id = ?
                    """), arguments: [account.rawValue, id.rawValue]) else { continue }
                mids.append(row["mid"])
                tids.insert(row["tid"])
            }
            let ops = try OperationTargets.linkedOperations(mids: mids, in: db)
            for mid in mids { try db.cached("DELETE FROM messages WHERE mid = ?").execute(arguments: [mid]) }
            try OperationTargets.cancelOrphans(ops, in: db)
            try ThreadAggregator.refresh(tids: tids, in: db)
            return UpsertResult(inserted: 0, updated: mids.count, skippedStale: 0, skippedTombstoned: 0,
                                touchedThreads: Set(tids.map { ThreadRowID(rawValue: $0) }), unknownLabelIDs: [])
        }
    }

    public func applyLabelDeltas(_ deltas: [LabelDelta], account: AccountID) throws -> UpsertResult {
        try write { db in
            try requireAccount(account, in: db)
            let known = Set(try String.fetchAll(db, sql: "SELECT key FROM labels WHERE account_id = ?",
                                                arguments: [account.rawValue]))
            let now = nowMillis()
            var updated = 0, stale = 0
            var mids = Set<Int64>(), tids = Set<Int64>()
            var unknown = Set<GmailLabelID>()
            let guarding = try EchoGuard.anyAwaiting(in: db)
            var echoed = Set<String>()
            for d in deltas {
                guard let row = try Row.fetchOne(db.cached("""
                    SELECT mid, tid, history_id, server_label_ids FROM messages WHERE account_id = ? AND gmail_message_id = ?
                    """), arguments: [account.rawValue, d.gmailMessageID.rawValue]) else { continue }
                let incoming = Int64(clamping: d.historyID.rawValue)
                let current: Int64 = row["history_id"]
                if incoming < current {
                    stale += 1
                    continue
                }
                var labels = Labels.split(row["server_label_ids"])
                if let full = d.fullSetIfKnown {
                    labels = Set(full.map(\.rawValue))
                } else {
                    labels.formUnion(d.added.map(\.rawValue))
                    labels.subtract(d.removed.map(\.rawValue))
                }
                for id in labels where !known.contains(id) { unknown.insert(GmailLabelID(id)) }
                let mid: Int64 = row["mid"]
                let joined = Labels.join(labels)
                if joined != (row["server_label_ids"] as String) || incoming != current {
                    try db.cached("""
                        UPDATE messages SET server_label_ids = ?, history_id = ?, updated_at = ? WHERE mid = ?
                        """).execute(arguments: [joined, incoming, now, mid])
                }
                if guarding {
                    try EchoGuard.record(mid: mid, account: account.rawValue, historyID: incoming,
                                         added: Set(d.added.map(\.rawValue)), removed: Set(d.removed.map(\.rawValue)),
                                         used: &echoed, in: db)
                }
                updated += 1
                mids.insert(mid)
                tids.insert(row["tid"])
            }
            try LabelOverlay.recompute(mids: mids, in: db)
            try ThreadAggregator.refresh(tids: tids, in: db)
            return UpsertResult(inserted: 0, updated: updated, skippedStale: stale, skippedTombstoned: 0,
                                touchedThreads: Set(tids.map { ThreadRowID(rawValue: $0) }), unknownLabelIDs: unknown)
        }
    }
}
