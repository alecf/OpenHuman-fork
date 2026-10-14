import Foundation
import GRDB
import OpenHumanCore

enum ThreadActions {
    static func labels(_ refs: [ThreadRef], add: [String], remove: [String], scope: TargetScope, origin: OperationOrigin,
                       undo: MailAction?, in db: Database) throws -> ActionReceipt {
        var ops: [OperationID] = []
        var mids = Set<Int64>(), tids = Set<Int64>()
        var delta = UndoDelta()
        for (account, accountTids) in MailStore.byAccount(refs) {
            try MailStore.requireWritableAccount(account, in: db)
            let targets = try Targets.select(account: account.rawValue, tids: accountTids, scope: scope, in: db)
            guard Targets.wouldChange(targets, add: add, remove: remove) else { continue }
            let op = try OpWriter.modifyLabels(account: account.rawValue, targets: targets, add: add, remove: remove,
                                               origin: origin, in: db)
            ops.append(OperationID(rawValue: op))
            delta.note(account, targets, add: add, remove: remove)
            for t in targets { mids.insert(t.mid); tids.insert(t.tid) }
        }
        try LabelOverlay.recompute(mids: mids, in: db)
        if remove.contains("INBOX") { try clearInboxFromDrafts(tids: tids, in: db) }
        try ThreadAggregator.refresh(tids: tids, in: db)
        return ActionReceipt(operationIDs: ops, undo: ops.isEmpty ? nil : undo,
                             exactUndo: ops.isEmpty ? nil : undo.flatMap { delta.exactUndo(of: $0) })
    }

    static func clearInboxFromDrafts(tids: Set<Int64>, in db: Database) throws {
        guard !tids.isEmpty else { return }
        let marks = Array(repeating: "?", count: tids.count).joined(separator: ", ")
        for r in try Row.fetchAll(db, sql: "SELECT mid, label_ids FROM messages WHERE is_draft = 1 AND tid IN (\(marks))",
                                  arguments: StatementArguments(tids.sorted())) {
            var labels = Labels.split(r["label_ids"])
            guard labels.remove("INBOX") != nil else { continue }
            try db.execute(sql: "UPDATE messages SET label_ids = ? WHERE mid = ?",
                           arguments: [Labels.join(labels), r["mid"] as Int64])
        }
    }

    // Gmail's `messages.untrash` does not restore INBOX, so a `modify_labels` op adding INBOX follows the untrash op
    static func trash(_ refs: [ThreadRef], untrash: Bool, origin: OperationOrigin, in db: Database) throws -> ActionReceipt {
        var ops: [OperationID] = []
        var mids = Set<Int64>(), tids = Set<Int64>()
        for (account, accountTids) in MailStore.byAccount(refs) {
            try MailStore.requireWritableAccount(account, in: db)
            let targets = try Targets.select(account: account.rawValue, tids: accountTids,
                                             scope: untrash ? .trashed : .notTrashed, in: db)
            guard !targets.isEmpty else { continue }
            let ids = targets.map { GmailMessageID($0.gmailID) }
            let op = try OpWriter.insert(account: account.rawValue, payload: untrash ? .untrash(ids: ids) : .trash(ids: ids),
                                         origin: origin, coalesceKey: nil, in: db)
            try OpWriter.link(op, mids: targets.map(\.mid), in: db)
            ops.append(OperationID(rawValue: op))
            if untrash {
                let inbox = try OpWriter.modifyLabels(account: account.rawValue, targets: targets, add: ["INBOX"], remove: [],
                                                      origin: origin, dependsOn: op, in: db)
                ops.append(OperationID(rawValue: inbox))
            }
            for t in targets { mids.insert(t.mid); tids.insert(t.tid) }
        }
        try LabelOverlay.recompute(mids: mids, in: db)
        try ThreadAggregator.refresh(tids: tids, in: db)
        let undo: MailAction = untrash ? .trash(refs) : .untrash(refs)
        let changed = undo.restricted(to: tids)
        return ActionReceipt(operationIDs: ops, undo: ops.isEmpty ? nil : undo,
                             exactUndo: ops.isEmpty || changed == undo ? nil : changed)
    }

    static func modifyLabels(_ refs: [ThreadRef], add: [GmailLabelID], remove: [GmailLabelID], origin: OperationOrigin,
                             in db: Database) throws -> ActionReceipt {
        var ops: [OperationID] = []
        var mids = Set<Int64>(), tids = Set<Int64>()
        var delta = UndoDelta()
        for (account, accountTids) in MailStore.byAccount(refs) {
            try MailStore.requireWritableAccount(account, in: db)
            let (addKeys, removeKeys) = try resolve(account: account.rawValue, add: add, remove: remove, in: db)
            guard !addKeys.isEmpty || !removeKeys.isEmpty else { continue }
            let targets = try Targets.select(account: account.rawValue, tids: accountTids, scope: .visibleElseNonDraft, in: db)
            guard Targets.wouldChange(targets, add: addKeys, remove: removeKeys) else { continue }
            let op = try OpWriter.modifyLabels(account: account.rawValue, targets: targets, add: addKeys, remove: removeKeys,
                                               origin: origin, in: db)
            ops.append(OperationID(rawValue: op))
            delta.note(account, targets, add: addKeys, remove: removeKeys)
            for t in targets { mids.insert(t.mid); tids.insert(t.tid) }
        }
        try LabelOverlay.recompute(mids: mids, in: db)
        try ThreadAggregator.refresh(tids: tids, in: db)
        let undo: MailAction = .modifyLabels(refs, add: remove, remove: add)
        return ActionReceipt(operationIDs: ops, undo: ops.isEmpty ? nil : undo,
                             exactUndo: ops.isEmpty ? nil : delta.exactUndo(of: undo))
    }

    static func modifyMessageLabels(_ account: AccountID, _ ids: [GmailMessageID], add: [GmailLabelID],
                                    remove: [GmailLabelID], origin: OperationOrigin, in db: Database) throws -> ActionReceipt {
        try MailStore.requireWritableAccount(account, in: db)
        let (addKeys, removeKeys) = try resolve(account: account.rawValue, add: add, remove: remove, in: db)
        var seen = Set<String>()
        let unique = ids.map(\.rawValue).filter { seen.insert($0).inserted }
        guard !unique.isEmpty, !addKeys.isEmpty || !removeKeys.isEmpty else { return ActionReceipt(operationIDs: []) }
        var targets: [OpTarget] = []
        for id in unique {
            if let r = try Row.fetchOne(db, sql: """
                SELECT mid, tid, label_ids FROM messages WHERE account_id = ? AND gmail_message_id = ?
                """, arguments: [account.rawValue, id]) {
                targets.append(OpTarget(mid: r["mid"], tid: r["tid"], gmailID: id, labels: Labels.split(r["label_ids"])))
            }
        }
        let known = Set(targets.map(\.gmailID))
        let op = try OpWriter.modifyLabels(account: account.rawValue, targets: targets,
                                           extraIDs: unique.filter { !known.contains($0) }, add: addKeys,
                                           remove: removeKeys, origin: origin, coalesce: origin != .scheduler, in: db)
        try LabelOverlay.recompute(mids: Set(targets.map(\.mid)), in: db)
        try ThreadAggregator.refresh(tids: Set(targets.map(\.tid)), in: db)
        return ActionReceipt(operationIDs: [OperationID(rawValue: op)],
                             undo: .modifyMessageLabels(account, ids, add: remove, remove: add))
    }

    static func resolve(account: Int64, add: [GmailLabelID], remove: [GmailLabelID],
                        in db: Database) throws -> (add: [String], remove: [String]) {
        let index = try LabelIndex.load(account: account, in: db)
        let entries = (add + remove).map(\.rawValue)
        try ReservedLabels.check(entries, index: index)
        for entry in entries where entry.hasPrefix("oh:") {
            throw StoreError.conflict("\(entry) is a local view, not a Gmail label")
        }
        var addKeys: [String] = []
        for entry in add.map(\.rawValue) {
            guard let key = index.resolve(entry) else { throw StoreError.notFound("label \(entry)") }
            if !addKeys.contains(key) { addKeys.append(key) }
        }
        var removeKeys: [String] = []
        for entry in remove.map(\.rawValue) {
            if let key = index.resolve(entry), !removeKeys.contains(key) { removeKeys.append(key) }
        }
        if let fixed = (addKeys + removeKeys).first(where: { $0 == "DRAFT" || $0 == "SENT" }) {
            throw StoreError.conflict("\(fixed) cannot be added or removed")
        }
        if let both = addKeys.first(where: removeKeys.contains) {
            throw StoreError.conflict("label \(both) is both added and removed")
        }
        return (addKeys, removeKeys)
    }
}

// An op covers messages already in the new state, so a symmetric inverse would change those too (undo of mark read would mark all unread)
struct UndoDelta {
    private struct Change: Hashable {
        var account: AccountID
        var gained: [String]
        var lost: [String]
    }

    private var changes: [Change] = []
    private var ids: [Change: [GmailMessageID]] = [:]
    private var threads = Set<Int64>()
    private var whole = true

    mutating func note(_ account: AccountID, _ targets: [OpTarget], add: [String], remove: [String]) {
        for t in targets {
            let change = Change(account: account, gained: add.filter { !t.labels.contains($0) },
                                lost: remove.filter { t.labels.contains($0) })
            if change.gained.count != add.count || change.lost.count != remove.count { whole = false }
            guard !change.gained.isEmpty || !change.lost.isEmpty else { continue }
            if ids[change] == nil { changes.append(change) }
            ids[change, default: []].append(GmailMessageID(t.gmailID))
            threads.insert(t.tid)
        }
    }

    func exactUndo(of undo: MailAction) -> MailAction? {
        if whole, Self.picksTheSameMessages(undo) { return nil }
        if changes.count == 1, let change = changes.first, let ids = ids[change] {
            return .modifyMessageLabels(change.account, ids, add: change.lost.map { GmailLabelID($0) },
                                        remove: change.gained.map { GmailLabelID($0) })
        }
        let changed = undo.restricted(to: threads)
        return changed == undo ? nil : changed
    }

    private static func picksTheSameMessages(_ undo: MailAction) -> Bool {
        switch undo {
        case .archive, .moveToInbox, .markRead, .markUnread, .modifyLabels: return true
        default: return false
        }
    }
}

extension MailAction {
    func restricted(to tids: Set<Int64>) -> MailAction {
        func keep(_ refs: [ThreadRef]) -> [ThreadRef] { refs.filter { tids.contains($0.rowID.rawValue) } }
        switch self {
        case let .archive(refs): return .archive(keep(refs))
        case let .moveToInbox(refs): return .moveToInbox(keep(refs))
        case let .trash(refs): return .trash(keep(refs))
        case let .untrash(refs): return .untrash(keep(refs))
        case let .markRead(refs): return .markRead(keep(refs))
        case let .markUnread(refs): return .markUnread(keep(refs))
        case let .star(refs): return .star(keep(refs))
        case let .unstar(refs): return .unstar(keep(refs))
        case let .markSpam(refs): return .markSpam(keep(refs))
        case let .markNotSpam(refs): return .markNotSpam(keep(refs))
        case let .modifyLabels(refs, add, remove): return .modifyLabels(keep(refs), add: add, remove: remove)
        default: return self
        }
    }
}
