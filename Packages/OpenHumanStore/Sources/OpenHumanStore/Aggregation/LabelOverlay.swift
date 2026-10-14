import Foundation
import GRDB

enum LabelOverlay {
    static func recompute(mids: Set<Int64>, in db: Database) throws {
        guard !mids.isEmpty else { return }
        var resolvers: [Int64: NameResolver] = [:]
        let anyLive = try Bool.fetchOne(db.cached("SELECT EXISTS (SELECT 1 FROM pending_op_messages)")) ?? true
        for mid in mids.sorted() {
            guard let row = try Row.fetchOne(db.cached("""
                SELECT account_id, server_label_ids, label_ids, is_unread, is_starred, is_draft, is_sent, in_trash, in_spam
                FROM messages WHERE mid = ?
                """), arguments: [mid]) else { continue }
            let account: Int64 = row["account_id"]
            var set = Labels.split(row["server_label_ids"])
            let ops = !anyLive ? [] : try Row.fetchAll(db.cached("""
                SELECT o.kind, o.payload_json FROM pending_op_messages pom
                JOIN pending_operations o ON o.op_id = pom.op_id
                WHERE pom.mid = ? AND o.status IN ('pending', 'in_flight', 'succeeded')
                ORDER BY o.op_id
                """), arguments: [mid])
            if !ops.isEmpty {
                let resolver = resolvers[account] ?? NameResolver(account: account)
                for op in ops {
                    guard let kind = OperationKind(rawValue: op["kind"]) else { continue }
                    try apply(OperationPayloadCodec.decode(kind: kind, json: op["payload_json"]), to: &set) {
                        try resolver.key(for: $0, in: db)
                    }
                }
                resolvers[account] = resolver
            }
            let joined = Labels.join(set)
            let flags = [set.contains("UNREAD"), set.contains("STARRED"), set.contains("DRAFT"), set.contains("SENT"),
                         set.contains("TRASH"), set.contains("SPAM")]
            let stored: [Bool] = [row["is_unread"], row["is_starred"], row["is_draft"], row["is_sent"], row["in_trash"],
                                  row["in_spam"]]
            if joined == (row["label_ids"] as String) && flags == stored { continue }
            try db.cached("""
                UPDATE messages SET label_ids = ?, is_unread = ?, is_starred = ?, is_draft = ?, is_sent = ?,
                                    in_trash = ?, in_spam = ?
                WHERE mid = ?
                """).execute(arguments: [joined, flags[0], flags[1], flags[2], flags[3], flags[4], flags[5], mid])
        }
    }

    static func apply(_ payload: OperationPayload, to set: inout Set<String>,
                      resolveName: (String) throws -> String?) rethrows {
        switch payload {
        case let .modifyLabels(_, add, remove, addNames):
            set.formUnion(add.map(\.rawValue))
            for name in addNames { if let key = try resolveName(name) { set.insert(key) } }
            set.subtract(remove.map(\.rawValue))
        case .trash:
            set.insert("TRASH")
            set.subtract(["INBOX", "SPAM"])
        case .untrash:
            set.remove("TRASH")
        case .upsertDraft, .deleteDraft, .sendDraft, .createLabel:
            break
        }
    }

    static func fold(_ payload: OperationPayload, into server: String) -> String {
        var set = Labels.split(server)
        apply(payload, to: &set) { _ in nil }
        return Labels.join(set)
    }

    static func fold(_ payload: OperationPayload, into server: String, account: Int64, in db: Database) throws -> String {
        var set = Labels.split(server)
        let resolver = NameResolver(account: account)
        try apply(payload, to: &set) { try resolver.key(for: $0, in: db) }
        return Labels.join(set)
    }

    static func pendingNames(mids: [Int64], account: Int64, knownNames: [String: String],
                             in db: Database) throws -> [Int64: [String]] {
        guard !mids.isEmpty else { return [:] }
        var out: [Int64: [String]] = [:]
        for chunk in stride(from: 0, to: mids.count, by: 500).map({ Array(mids[$0..<min($0 + 500, mids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            for row in try Row.fetchAll(db, sql: """
                SELECT pom.mid, o.payload_json FROM pending_op_messages pom
                JOIN pending_operations o ON o.op_id = pom.op_id
                WHERE pom.mid IN (\(marks)) AND o.status IN ('pending', 'in_flight') AND o.kind = 'modify_labels'
                  AND instr(o.payload_json, '"addNames"') > 0
                ORDER BY o.op_id
                """, arguments: StatementArguments(chunk)) {
                guard case let .modifyLabels(_, _, _, names) = try OperationPayloadCodec.decode(
                    kind: .modifyLabels, json: row["payload_json"]) else { continue }
                let pending = names.filter { knownNames[$0] == nil }
                if !pending.isEmpty { out[row["mid"], default: []].append(contentsOf: pending) }
            }
        }
        return out
    }

    static func labelRowsCreated(account: Int64, names: Set<String>, in db: Database) throws -> Set<Int64> {
        guard !names.isEmpty else { return [] }
        var mids = Set<Int64>(), tids = Set<Int64>()
        for row in try Row.fetchAll(db.cached("""
            SELECT op_id, payload_json FROM pending_operations
            WHERE account_id = ? AND status IN ('pending', 'in_flight') AND kind = 'modify_labels'
              AND instr(payload_json, '"addNames"') > 0
            """), arguments: [account]) {
            guard case let .modifyLabels(_, _, _, added) = try OperationPayloadCodec.decode(
                kind: .modifyLabels, json: row["payload_json"]), !names.isDisjoint(with: added) else { continue }
            for r in try Row.fetchAll(db.cached("""
                SELECT m.mid, m.tid FROM pending_op_messages pom JOIN messages m ON m.mid = pom.mid WHERE pom.op_id = ?
                """), arguments: [row["op_id"] as Int64]) {
                mids.insert(r["mid"]); tids.insert(r["tid"])
            }
        }
        try recompute(mids: mids, in: db)
        return tids
    }

    final class NameResolver {
        let account: Int64
        private var cache: [String: String?] = [:]
        init(account: Int64) { self.account = account }

        func key(for name: String, in db: Database) throws -> String? {
            if let hit = cache[name] { return hit }
            let key = try String.fetchOne(db.cached("""
                SELECT key FROM labels WHERE account_id = ? AND name = ? AND kind IN ('system', 'category', 'user')
                """), arguments: [account, name])
            cache[name] = key
            return key
        }
    }
}
