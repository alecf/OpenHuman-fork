import Foundation
import GRDB
import OpenHumanCore

struct OpTarget {
    var mid: Int64
    var tid: Int64
    var gmailID: String
    var labels: Set<String>
}

enum TargetScope {
    case visible
    case visibleElseNonDraft
    case latest
    case starred
    case notTrashed
    case trashed
    case spam
}

enum Targets {
    static func select(account: Int64, tids: [Int64], scope: TargetScope, in db: Database) throws -> [OpTarget] {
        let unique = Array(Set(tids)).sorted()
        guard !unique.isEmpty else { return [] }
        var byThread: [Int64: [(target: OpTarget, trash: Bool, spam: Bool)]] = [:]
        for chunk in stride(from: 0, to: unique.count, by: 500).map({ Array(unique[$0..<min($0 + 500, unique.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            for r in try Row.fetchAll(db, sql: """
                SELECT mid, tid, gmail_message_id, label_ids, in_trash, in_spam FROM messages
                WHERE account_id = ? AND tid IN (\(marks)) AND is_draft = 0
                ORDER BY tid, internal_date, mid
                """, arguments: StatementArguments([account] + chunk)) {
                let t = OpTarget(mid: r["mid"], tid: r["tid"], gmailID: r["gmail_message_id"], labels: Labels.split(r["label_ids"]))
                byThread[t.tid, default: []].append((t, r["in_trash"], r["in_spam"]))
            }
        }
        var out: [OpTarget] = []
        for tid in unique {
            let all = byThread[tid] ?? []
            let visible = all.filter { !$0.trash && !$0.spam }.map(\.target)
            switch scope {
            case .visible: out += visible
            case .visibleElseNonDraft: out += visible.isEmpty ? all.map(\.target) : visible
            case .latest:
                if let last = (visible.isEmpty ? all.map(\.target) : visible).last { out.append(last) }
            case .starred: out += all.map(\.target).filter { $0.labels.contains("STARRED") }
            case .notTrashed: out += all.filter { !$0.trash }.map(\.target)
            case .trashed: out += all.filter(\.trash).map(\.target)
            case .spam: out += all.filter(\.spam).map(\.target)
            }
        }
        return out
    }

    static func wouldChange(_ targets: [OpTarget], add: [String], remove: [String]) -> Bool {
        targets.contains { t in add.contains { !t.labels.contains($0) } || remove.contains { t.labels.contains($0) } }
    }
}

enum OpWriter {
    static func insert(account: Int64, payload: OperationPayload, origin: OperationOrigin, coalesceKey: String?,
                       dependsOn: Int64? = nil, notBefore: Int64 = 0, in db: Database) throws -> Int64 {
        let now = nowMillis()
        try db.execute(sql: """
            INSERT INTO pending_operations (account_id, kind, payload_json, status, not_before, depends_on, coalesce_key,
                                            origin, created_at, updated_at)
            VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?)
            """, arguments: [account, OperationPayloadCodec.kind(of: payload).rawValue, OperationPayloadCodec.encode(payload),
                             notBefore, dependsOn, coalesceKey, origin.rawValue, now, now])
        return db.lastInsertedRowID
    }

    static func link(_ op: Int64, mids: some Sequence<Int64>, in db: Database) throws {
        for mid in mids {
            try db.execute(sql: "INSERT OR IGNORE INTO pending_op_messages (mid, op_id) VALUES (?, ?)", arguments: [mid, op])
        }
    }

    static func modifyLabels(account: Int64, targets: [OpTarget], extraIDs: [String] = [], add: [String],
                             remove: [String], addNames: [String] = [], origin: OperationOrigin, coalesce: Bool = true,
                             dependsOn: Int64? = nil, notBefore: Int64 = 0, in db: Database) throws -> Int64 {
        var seen = Set<String>()
        let ids = (targets.map(\.gmailID) + extraIDs).filter { seen.insert($0).inserted }.map { GmailMessageID($0) }
        let addIDs = add.map { GmailLabelID($0) }, removeIDs = remove.map { GmailLabelID($0) }
        let key = coalesce ? OperationPayloadCodec.labelsCoalesceKey(account: AccountID(account), add: addIDs,
                                                                     remove: removeIDs, addNames: addNames) : nil
        let op = try insert(account: account, payload: .modifyLabels(ids: ids, add: addIDs, remove: removeIDs, addNames: addNames),
                            origin: origin, coalesceKey: key, dependsOn: dependsOn, notBefore: notBefore, in: db)
        try link(op, mids: targets.map(\.mid), in: db)
        return op
    }
}

struct LabelIndex {
    let nameByKey: [String: String]
    let keyByName: [String: String]

    static func load(account: Int64, in db: Database) throws -> LabelIndex {
        var nameByKey: [String: String] = [:], keyByName: [String: String] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT key, name FROM labels WHERE account_id = ? AND kind IN ('system', 'category', 'user')
            """, arguments: [account]) {
            nameByKey[r["key"]] = r["name"]
            keyByName[r["name"]] = r["key"]
        }
        return LabelIndex(nameByKey: nameByKey, keyByName: keyByName)
    }

    func resolve(_ idOrName: String) -> String? {
        if nameByKey[idOrName] != nil { return idOrName }
        return keyByName[idOrName]
    }

    func name(of key: String) -> String? { nameByKey[key] }
}

enum ReservedLabels {
    static func check(_ entries: [String], index: LabelIndex) throws {
        for entry in entries {
            if ScheduleLabel.parse(entry) != .notOurs { throw StoreError.reservedLabel(entry) }
            if let key = index.resolve(entry), let name = index.name(of: key), ScheduleLabel.parse(name) != .notOurs {
                throw StoreError.reservedLabel(name)
            }
        }
    }
}

extension MailStore {
    static func requireWritableAccount(_ id: AccountID, in db: Database) throws {
        guard let status = try String.fetchOne(db, sql: "SELECT status FROM accounts WHERE account_id = ?",
                                               arguments: [id.rawValue]) else {
            throw StoreError.notFound("account \(id.rawValue)")
        }
        if status == AccountStatus.removing.rawValue || status == AccountStatus.disabled.rawValue {
            throw StoreError.accountNotActive(id)
        }
    }

    static func requireThread(_ ref: ThreadRef, in db: Database) throws -> Row {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM threads WHERE tid = ? AND account_id = ?",
                                         arguments: [ref.rowID.rawValue, ref.accountID.rawValue]) else {
            throw StoreError.notFound("thread \(ref.rowID.rawValue)")
        }
        return row
    }

    static func byAccount(_ refs: [ThreadRef]) -> [(account: AccountID, tids: [Int64])] {
        Dictionary(grouping: refs, by: \.accountID).keys.sorted().map { account in
            (account, refs.filter { $0.accountID == account }.map(\.rowID.rawValue))
        }
    }

    static func snoozeMarkUnread(in db: Database) throws -> Bool {
        guard let json = try String.fetchOne(db, sql: "SELECT value_json FROM settings WHERE scope = 'global' AND key = ?",
                                             arguments: [SettingKey<Bool>.snoozeMarkUnread.name]),
              let value = try? JSONDecoder().decode(Bool.self, from: Data(json.utf8)) else {
            return SettingKey<Bool>.snoozeMarkUnread.defaultValue
        }
        return value
    }

    static func boost(tids: some Sequence<Int64>, at millis: Int64, in db: Database) throws {
        for tid in tids {
            try db.execute(sql: "UPDATE threads SET sort_boost_at = ? WHERE tid = ?", arguments: [millis, tid])
        }
    }

    static func windowMillis(_ duration: Duration) -> Int64 {
        let c = duration.components
        let limit: Int64 = c.seconds < 0 ? .min : .max
        let (millis, overflow) = c.seconds.multipliedReportingOverflow(by: 1000)
        if overflow { return limit }
        let (total, overflowAgain) = millis.addingReportingOverflow(c.attoseconds / 1_000_000_000_000_000)
        return overflowAgain ? limit : total
    }
}
