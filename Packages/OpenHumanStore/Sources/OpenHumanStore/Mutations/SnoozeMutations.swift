import Foundation
import GRDB
import OpenHumanCore

enum SnoozeMutations {
    static let marker = OHGmailLabels.snoozed
    static let scheduleLabelLimit = 8_000

    struct ThreadState {
        var ref: ThreadRef
        var targets: [OpTarget]
        var stampKeys: Set<String>
        var pendingStampNames: Set<String>
        var malformedKeys: Set<String>
        var hasMarker: Bool
        var inInbox: Bool
        var cache: Previous = .notSnoozed

        var isSnoozed: Bool { cache != .notSnoozed || !stampKeys.isEmpty || !pendingStampNames.isEmpty || !malformedKeys.isEmpty || hasMarker }
    }

    enum Previous: Equatable {
        case notSnoozed, active(wakeAt: Int64), malformed

        static func commonWake(_ list: [Previous]) -> Int64? {
            guard case let .active(wake)? = list.first, list.allSatisfy({ $0 == .active(wakeAt: wake) }) else { return nil }
            return wake
        }
    }

    static func load(_ ref: ThreadRef, index: LabelIndex, in db: Database) throws -> ThreadState? {
        guard let thread = try Row.fetchOne(db, sql: "SELECT in_inbox FROM threads WHERE tid = ? AND account_id = ?",
                                            arguments: [ref.rowID.rawValue, ref.accountID.rawValue]) else { return nil }
        let account = ref.accountID.rawValue
        let targets = try Targets.select(account: account, tids: [ref.rowID.rawValue], scope: .visible, in: db)
        let pending = try LabelOverlay.pendingNames(mids: targets.map(\.mid), account: account,
                                                    knownNames: index.keyByName, in: db)
        var state = ThreadState(ref: ref, targets: targets, stampKeys: [], pendingStampNames: [], malformedKeys: [],
                                hasMarker: false, inInbox: thread["in_inbox"])
        for t in targets {
            for key in t.labels {
                guard let name = index.name(of: key) else { continue }
                classify(name, key: key, into: &state)
            }
            for name in pending[t.mid] ?? [] { classify(name, key: nil, into: &state) }
        }
        if let r = try Row.fetchOne(db, sql: "SELECT status, wake_at FROM snoozes WHERE tid = ?", arguments: [ref.rowID.rawValue]) {
            let wake: Int64? = r["wake_at"]
            state.cache = (r["status"] as String) == "active" ? wake.map { .active(wakeAt: $0) } ?? .malformed : .malformed
        }
        return state
    }

    private static func classify(_ name: String, key: String?, into state: inout ThreadState) {
        switch ScheduleLabel.parse(name) {
        case let .schedule(label) where label.kind == .snoozed:
            if let key { state.stampKeys.insert(key) } else { state.pendingStampNames.insert(name) }
        case .marker(.snoozed):
            state.hasMarker = true
        case .malformed(.snoozed):
            if let key { state.malformedKeys.insert(key) }
        default:
            break
        }
    }

    static func snooze(_ refs: [ThreadRef], until: Date, origin: OperationOrigin, in db: Database) throws -> ActionReceipt {
        let label = ScheduleLabel(kind: .snoozed, due: until)
        let stamp = label.name
        var ops: [OperationID] = []
        var previous: [Previous] = []
        var acted: [ThreadRef] = []
        var anyInInbox = false
        var mids = Set<Int64>(), tids = Set<Int64>()

        for (account, accountTids) in MailStore.byAccount(refs) {
            try MailStore.requireWritableAccount(account, in: db)
            let a = account.rawValue
            var index = try LabelIndex.load(account: a, in: db)
            let accountRefs = refs.filter { $0.accountID == account && accountTids.contains($0.rowID.rawValue) }
            var states = try unique(accountRefs).compactMap { try load($0, index: index, in: db) }
            func alreadyThere(_ s: ThreadState) -> Bool {
                let names = Set(s.stampKeys.compactMap(index.name(of:))).union(s.pendingStampNames)
                return names == [stamp] && s.malformedKeys.isEmpty && s.hasMarker && !s.inInbox
            }
            states = states.filter { !$0.targets.isEmpty && !alreadyThere($0) }
            guard !states.isEmpty else { continue }
            for s in states {
                acted.append(s.ref)
                previous.append(s.cache)
                if s.inInbox { anyInInbox = true }
            }
            let held = states.filter { !$0.pendingStampNames.subtracting([stamp]).isEmpty }
            if !held.isEmpty {
                let touched = try detachPendingStamps(mids: held.flatMap { $0.targets.map(\.mid) }, keeping: stamp, in: db)
                try LabelOverlay.recompute(mids: touched.mids, in: db)
                try ThreadAggregator.refresh(tids: touched.tids, in: db)
                index = try LabelIndex.load(account: a, in: db)
                states = try states.compactMap { try load($0.ref, index: index, in: db) }
            }

            let markerKey = index.keyByName[marker], stampKey = index.keyByName[stamp]
            let add = [markerKey, stampKey].compactMap { $0 }
            let addNames = [markerKey == nil ? marker : nil, stampKey == nil ? stamp : nil].compactMap { $0 }
            if stampKey == nil { try checkBudget(account: a, in: db) }
            var dependsOn: Int64?
            for name in addNames {
                let (id, inserted) = try ensureCreateLabel(name, account: a, origin: origin, after: dependsOn, in: db)
                if inserted { ops.append(OperationID(rawValue: id)) }
                dependsOn = id
            }
            var remove: Set<String> = ["INBOX"]
            for s in states { remove.formUnion(s.stampKeys); remove.formUnion(s.malformedKeys) }
            if let stampKey { remove.remove(stampKey) }
            let targets = states.flatMap(\.targets)
            let op = try OpWriter.modifyLabels(account: a, targets: targets, add: add, remove: remove.sorted(),
                                               addNames: addNames, origin: origin, dependsOn: dependsOn, in: db)
            ops.append(OperationID(rawValue: op))
            for t in targets { mids.insert(t.mid); tids.insert(t.tid) }
        }
        try LabelOverlay.recompute(mids: mids, in: db)
        try ThreadAggregator.refresh(tids: tids, in: db)
        guard !ops.isEmpty else { return ActionReceipt(operationIDs: []) }
        let undo: MailAction?
        let fresh = previous.allSatisfy({ $0 == .notSnoozed })
        if fresh {
            undo = .unsnooze(acted)
        } else if let wake = Previous.commonWake(previous) {
            undo = .snooze(acted, until: MailStore.storeDate(millis: wake))
        } else {
            undo = nil
        }
        return ActionReceipt(operationIDs: ops, undo: undo, exactUndo: fresh && !anyInInbox ? .clearSnooze(acted) : nil)
    }

    static func unsnooze(_ refs: [ThreadRef], toInbox: Bool = true, origin: OperationOrigin,
                         in db: Database) throws -> ActionReceipt {
        var ops: [OperationID] = []
        var previous: [Previous] = []
        var acted: [ThreadRef] = []
        var mids = Set<Int64>(), tids = Set<Int64>()
        let markUnread = toInbox ? try MailStore.snoozeMarkUnread(in: db) : false
        let now = nowMillis()

        for (account, accountTids) in MailStore.byAccount(refs) {
            try MailStore.requireWritableAccount(account, in: db)
            let a = account.rawValue
            var index = try LabelIndex.load(account: a, in: db)
            let accountRefs = refs.filter { $0.accountID == account && accountTids.contains($0.rowID.rawValue) }
            var states = try unique(accountRefs).compactMap { try load($0, index: index, in: db) }
                .filter { $0.isSnoozed && !$0.targets.isEmpty }
            guard !states.isEmpty else { continue }
            for s in states {
                acted.append(s.ref)
                previous.append(s.cache)
            }
            if states.contains(where: { !$0.pendingStampNames.isEmpty }) {
                let touched = try detachPendingStamps(mids: states.flatMap { $0.targets.map(\.mid) }, keeping: nil, in: db)
                try LabelOverlay.recompute(mids: touched.mids, in: db)
                try ThreadAggregator.refresh(tids: touched.tids, in: db)
                for t in touched.tids { tids.insert(t) }
                index = try LabelIndex.load(account: a, in: db)
                states = try states.compactMap { try load($0.ref, index: index, in: db) }.filter(\.isSnoozed)
            }
            guard !states.isEmpty else { continue }
            var remove = Set<String>()
            if let markerKey = index.keyByName[marker] { remove.insert(markerKey) }
            for s in states { remove.formUnion(s.stampKeys); remove.formUnion(s.malformedKeys) }
            let add = !toInbox ? [] : markUnread ? ["INBOX", "UNREAD"] : ["INBOX"]
            let targets = states.flatMap(\.targets)
            let op = try OpWriter.modifyLabels(account: a, targets: targets, add: add, remove: remove.sorted(),
                                               origin: origin, in: db)
            ops.append(OperationID(rawValue: op))
            if toInbox { try MailStore.boost(tids: Set(targets.map(\.tid)), at: now, in: db) }
            for t in targets { mids.insert(t.mid); tids.insert(t.tid) }
        }
        try LabelOverlay.recompute(mids: mids, in: db)
        try ThreadAggregator.refresh(tids: tids, in: db)
        guard !acted.isEmpty else { return ActionReceipt(operationIDs: []) }
        let undo = Previous.commonWake(previous).map { MailAction.snooze(acted, until: MailStore.storeDate(millis: $0)) }
        if ops.isEmpty && undo == nil { return ActionReceipt(operationIDs: []) }
        return ActionReceipt(operationIDs: ops, undo: undo)
    }

    static func ensureCreateLabel(_ name: String, account: Int64, origin: OperationOrigin, after: Int64?,
                                  in db: Database) throws -> (id: Int64, inserted: Bool) {
        for row in try Row.fetchAll(db, sql: """
            SELECT op_id, payload_json FROM pending_operations
            WHERE account_id = ? AND kind = 'create_label' AND status IN ('pending', 'in_flight') ORDER BY op_id
            """, arguments: [account]) {
            if case let .createLabel(existing) = try OperationPayloadCodec.decode(kind: .createLabel, json: row["payload_json"]),
               existing == name {
                return (row["op_id"], false)
            }
        }
        let id = try OpWriter.insert(account: account, payload: .createLabel(name: name), origin: origin, coalesceKey: nil,
                                     dependsOn: after, in: db)
        return (id, true)
    }

    static func checkBudget(account: Int64, in db: Database) throws {
        var count = 0
        for name in try String.fetchAll(db, sql: """
            SELECT name FROM labels WHERE account_id = ? AND name LIKE 'OpenHuman/%'
            """, arguments: [account]) {
            if case .schedule = ScheduleLabel.parse(name) { count += 1 }
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT payload_json FROM pending_operations
            WHERE account_id = ? AND kind = 'create_label' AND status IN ('pending', 'in_flight')
            """, arguments: [account]) {
            if case let .createLabel(name) = try OperationPayloadCodec.decode(kind: .createLabel, json: row["payload_json"]),
               case .schedule = ScheduleLabel.parse(name) { count += 1 }
        }
        if count >= scheduleLabelLimit { throw StoreError.limitExceeded("labels") }
    }

    static func detachPendingStamps(mids: [Int64], keeping: String?, in db: Database) throws -> (mids: Set<Int64>, tids: Set<Int64>) {
        guard !mids.isEmpty else { return ([], []) }
        var touchedMids = Set<Int64>(), touchedTids = Set<Int64>()
        let wanted = Set(mids)
        let marks = Array(repeating: "?", count: wanted.count).joined(separator: ", ")
        let ops = try Row.fetchAll(db, sql: """
            SELECT DISTINCT o.op_id, o.payload_json, o.depends_on FROM pending_operations o
            JOIN pending_op_messages pom ON pom.op_id = o.op_id
            WHERE pom.mid IN (\(marks)) AND o.kind = 'modify_labels' AND o.status = 'pending' AND o.attempts = 0
              AND instr(o.payload_json, '"addNames"') > 0
            ORDER BY o.op_id
            """, arguments: StatementArguments(Array(wanted)))
        for op in ops {
            let id: Int64 = op["op_id"]
            guard case let .modifyLabels(ids, add, remove, names) = try OperationPayloadCodec.decode(
                kind: .modifyLabels, json: op["payload_json"]) else { continue }
            let holdsStamp = names.contains { name in
                if case let .schedule(l) = ScheduleLabel.parse(name), l.kind == .snoozed, name != keeping { return true }
                return false
            }
            guard holdsStamp else { continue }
            let linked = try MailStore.linkedMessages(op: id, in: db)
            let detached = linked.filter { wanted.contains($0.mid) }
            guard !detached.isEmpty else { continue }
            let gone = Set(try detached.compactMap { d in
                try String.fetchOne(db, sql: "SELECT gmail_message_id FROM messages WHERE mid = ?", arguments: [d.mid])
            })
            for d in detached {
                try db.execute(sql: "DELETE FROM pending_op_messages WHERE op_id = ? AND mid = ?", arguments: [id, d.mid])
                touchedMids.insert(d.mid); touchedTids.insert(d.tid)
            }
            let left = ids.filter { !gone.contains($0.rawValue) }
            if left.isEmpty || linked.count == detached.count {
                try db.execute(sql: """
                    UPDATE pending_operations SET status = 'cancelled', last_error_code = 'superseded',
                        last_error_message = 'replaced by a newer snooze change', updated_at = ?
                    WHERE op_id = ?
                    """, arguments: [nowMillis(), id])
                try db.execute(sql: "DELETE FROM pending_op_messages WHERE op_id = ?", arguments: [id])
                if let create: Int64 = op["depends_on"] { _ = try MailStore.cancelUnneededCreateLabel(create, in: db) }
            } else {
                try db.execute(sql: "UPDATE pending_operations SET payload_json = ?, updated_at = ? WHERE op_id = ?",
                               arguments: [OperationPayloadCodec.encode(.modifyLabels(ids: left, add: add, remove: remove,
                                                                                      addNames: names)),
                                           nowMillis(), id])
            }
        }
        return (touchedMids, touchedTids)
    }

    private static func unique(_ refs: [ThreadRef]) -> [ThreadRef] {
        var seen = Set<Int64>()
        return refs.filter { seen.insert($0.rowID.rawValue).inserted }
    }
}
