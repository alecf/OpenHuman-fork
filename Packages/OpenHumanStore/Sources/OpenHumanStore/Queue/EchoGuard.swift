// A succeeded label op keeps its overlay until Gmail's echo arrives, so a sync that read Gmail earlier cannot revert it
import Foundation
import GRDB
import OpenHumanCore

extension MailStore {
    public static let echoGuardWindow: Duration = .seconds(300)
}

enum EchoGuard {
    static let kinds: Set<OperationKind> = [.modifyLabels, .trash, .untrash]

    static func anyAwaiting(in db: Database) throws -> Bool {
        try Bool.fetchOne(db.cached("""
            SELECT EXISTS (SELECT 1 FROM pending_op_messages pom JOIN pending_operations o ON o.op_id = pom.op_id
                           WHERE o.status = 'succeeded')
            """)) ?? false
    }

    struct Awaiting {
        var op: Int64
        var payload: OperationPayload
    }

    static func awaiting(mid: Int64, in db: Database) throws -> [Awaiting] {
        try Row.fetchAll(db.cached("""
            SELECT o.op_id, o.kind, o.payload_json FROM pending_op_messages pom
            JOIN pending_operations o ON o.op_id = pom.op_id
            WHERE pom.mid = ? AND o.status = 'succeeded'
            ORDER BY o.op_id
            """), arguments: [mid]).compactMap { row in
            guard let kind = OperationKind(rawValue: row["kind"]) else { return nil }
            return Awaiting(op: row["op_id"], payload: try OperationPayloadCodec.decode(kind: kind, json: row["payload_json"]))
        }
    }

    static func change(of payload: OperationPayload, resolver: LabelOverlay.NameResolver,
                       in db: Database) throws -> (add: Set<String>, remove: Set<String>) {
        switch payload {
        case let .modifyLabels(_, add, remove, names):
            var added = Set(add.map(\.rawValue))
            for name in names { if let key = try resolver.key(for: name, in: db) { added.insert(key) } }
            return (added, Set(remove.map(\.rawValue)))
        case .trash: return (["TRASH"], ["INBOX", "SPAM"])
        case .untrash: return ([], ["TRASH"])
        case .upsertDraft, .deleteDraft, .sendDraft, .createLabel: return ([], [])
        }
    }

    @discardableResult
    static func record(mid: Int64, account: Int64, historyID: Int64, added: Set<String>, removed: Set<String>,
                       used: inout Set<String>, in db: Database) throws -> Bool {
        let key = "\(mid):\(historyID)"
        guard !used.contains(key) else { return false }
        let resolver = LabelOverlay.NameResolver(account: account)
        for candidate in try awaiting(mid: mid, in: db) {
            let op = try change(of: candidate.payload, resolver: resolver, in: db)
            guard !op.add.isDisjoint(with: added) || !op.remove.isDisjoint(with: removed) else { continue }
            try end(op: candidate.op, mid: mid, in: db)
            used.insert(key)
            return true
        }
        return false
    }

    static func snapshot(mid: Int64, account: Int64, labels: Set<String>, in db: Database) throws {
        let ops = try awaiting(mid: mid, in: db)
        guard !ops.isEmpty else { return }
        let resolver = LabelOverlay.NameResolver(account: account)
        var result = labels
        for op in ops { try LabelOverlay.apply(op.payload, to: &result) { try resolver.key(for: $0, in: db) } }
        guard result == labels else { return }
        for op in ops { try end(op: op.op, mid: mid, in: db) }
    }

    static func expire(succeededBefore cutoff: Int64, in db: Database) throws -> (mids: Set<Int64>, tids: Set<Int64>) {
        let rows = try Row.fetchAll(db, sql: """
            SELECT pom.op_id, m.mid, m.tid FROM pending_op_messages pom
            JOIN pending_operations o ON o.op_id = pom.op_id
            JOIN messages m ON m.mid = pom.mid
            WHERE o.status = 'succeeded' AND o.updated_at < ?
            """, arguments: [cutoff])
        var mids = Set<Int64>(), tids = Set<Int64>()
        for row in rows {
            try end(op: row["op_id"], mid: row["mid"], in: db)
            mids.insert(row["mid"])
            tids.insert(row["tid"])
        }
        return (mids, tids)
    }

    static func expireAndRefresh(now: Int64, in db: Database) throws {
        guard try anyAwaiting(in: db) else { return }
        let cutoff = now - Int64(MailStore.echoGuardWindow.components.seconds * 1000)
        let ended = try expire(succeededBefore: cutoff, in: db)
        try LabelOverlay.recompute(mids: ended.mids, in: db)
        try ThreadAggregator.refresh(tids: ended.tids, in: db)
    }

    private static func end(op: Int64, mid: Int64, in db: Database) throws {
        try db.execute(sql: "DELETE FROM pending_op_messages WHERE op_id = ? AND mid = ?", arguments: [op, mid])
    }
}
