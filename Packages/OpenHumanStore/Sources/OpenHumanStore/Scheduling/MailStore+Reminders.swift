import Foundation
import GRDB
import OpenHumanCore

extension MailStore: ReminderStoring {
    public func fireReminder(_ id: String, now: Date, satisfied: Bool) throws -> ActionReceipt? {
        try write { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT * FROM reminders WHERE reminder_id = ?", arguments: [id]),
                  (r["state"] as String) == "active" else { return nil }
            let tid: Int64 = r["tid"], account: Int64 = r["account_id"]
            func finish(_ state: String) throws {
                try db.execute(sql: "UPDATE reminders SET state = ? WHERE reminder_id = ?", arguments: [state, id])
            }
            let ifNoReply = (r["condition"] as String) == ReminderCondition.ifNoReply.rawValue
            let replied = try ifNoReply && Self.hasReply(tid: tid, account: account, anchor: r["anchor_message_id"], in: db)
            if satisfied || replied {
                try finish("satisfied")
                try ThreadAggregator.refresh(tids: [tid], in: db)
                return nil
            }
            let targets = try Targets.select(account: account, tids: [tid], scope: .visible, in: db)
            guard !targets.isEmpty else {
                try finish("cancelled")
                try ThreadAggregator.refresh(tids: [tid], in: db)
                return nil
            }
            try finish("fired")
            if try Int.fetchOne(db, sql: "SELECT 1 FROM snoozes WHERE tid = ?", arguments: [tid]) != nil {
                try ThreadAggregator.refresh(tids: [tid], in: db)
                return nil
            }
            let t = Self.storeMillis(now)
            let op = try OpWriter.modifyLabels(account: account, targets: targets, add: ["INBOX"], remove: [],
                                               origin: .scheduler, coalesce: false, notBefore: t, in: db)
            try Self.boost(tids: [tid], at: t, in: db)
            try LabelOverlay.recompute(mids: Set(targets.map(\.mid)), in: db)
            try ThreadAggregator.refresh(tids: [tid], in: db)
            return ActionReceipt(operationIDs: [OperationID(rawValue: op)], undo: nil)
        }
    }

    public func hasReplySince(_ thread: ThreadRef, anchor: GmailMessageID?) throws -> Bool {
        try read { db in
            let stored = try String.fetchOne(db, sql: """
                SELECT anchor_message_id FROM reminders WHERE tid = ? AND state = 'active'
                """, arguments: [thread.rowID.rawValue])
            return try Self.hasReply(tid: thread.rowID.rawValue, account: thread.accountID.rawValue,
                                     anchor: anchor?.rawValue ?? stored, in: db)
        }
    }

    public func activeReminders(account: AccountID?, limit: Int) throws -> [ReminderSummary] {
        try read { db in try ScheduleRows.activeReminders(account: account, limit: limit, in: db) }
    }

    static func hasReply(tid: Int64, account: Int64, anchor: String?, in db: Database) throws -> Bool {
        guard let anchor else {
            return try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM messages WHERE tid = ? AND is_draft = 0 AND in_trash = 0 AND in_spam = 0
                               AND is_from_me = 0)
                """, arguments: [tid]) ?? false
        }
        guard let a = try Row.fetchOne(db, sql: """
            SELECT internal_date, mid FROM messages WHERE account_id = ? AND gmail_message_id = ?
            """, arguments: [account, anchor]) else { return false }
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM messages WHERE tid = ? AND is_draft = 0 AND in_trash = 0 AND in_spam = 0
                           AND is_from_me = 0 AND (internal_date > ? OR (internal_date = ? AND mid > ?)))
            """, arguments: [tid, a["internal_date"] as Int64, a["internal_date"] as Int64, a["mid"] as Int64]) ?? false
    }
}
