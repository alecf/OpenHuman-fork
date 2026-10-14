import Foundation
import GRDB
import OpenHumanCore

enum ReminderMutations {
    struct Active {
        var id: String
        var dueAt: Int64
        var condition: ReminderCondition
    }

    static func active(tid: Int64, in db: Database) throws -> Active? {
        try Row.fetchOne(db, sql: "SELECT reminder_id, due_at, condition FROM reminders WHERE tid = ? AND state = 'active'",
                         arguments: [tid]).map {
            Active(id: $0["reminder_id"], dueAt: $0["due_at"], condition: ReminderCondition(rawValue: $0["condition"]) ?? .always)
        }
    }

    static func set(_ ref: ThreadRef, dueAt: Date, condition: ReminderCondition, in db: Database) throws -> ActionReceipt {
        try MailStore.requireWritableAccount(ref.accountID, in: db)
        let thread = try MailStore.requireThread(ref, in: db)
        let tid = ref.rowID.rawValue
        let due = MailStore.storeMillis(dueAt)
        let previous = try active(tid: tid, in: db)
        if let previous, previous.dueAt == due, previous.condition == condition { return ActionReceipt(operationIDs: []) }
        let now = nowMillis()
        if let previous {
            try db.execute(sql: "UPDATE reminders SET state = 'cancelled' WHERE reminder_id = ?", arguments: [previous.id])
        }
        try db.execute(sql: """
            INSERT INTO reminders (reminder_id, tid, account_id, gmail_thread_id, set_at, due_at, condition,
                                   anchor_message_id, state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active')
            """, arguments: [UUID().uuidString, tid, ref.accountID.rawValue, thread["gmail_thread_id"] as String, now, due,
                             condition.rawValue, try anchor(tid: tid, in: db)])
        try ThreadAggregator.refresh(tids: [tid], in: db)
        let undo: MailAction = previous.map {
            .setReminder(ref, dueAt: MailStore.storeDate(millis: $0.dueAt), condition: $0.condition)
        } ?? .cancelReminder(ref)
        return ActionReceipt(operationIDs: [], undo: undo)
    }

    static func cancel(_ ref: ThreadRef, in db: Database) throws -> ActionReceipt {
        try MailStore.requireWritableAccount(ref.accountID, in: db)
        _ = try MailStore.requireThread(ref, in: db)
        guard let previous = try active(tid: ref.rowID.rawValue, in: db) else { return ActionReceipt(operationIDs: []) }
        try db.execute(sql: "UPDATE reminders SET state = 'cancelled' WHERE reminder_id = ?", arguments: [previous.id])
        try ThreadAggregator.refresh(tids: [ref.rowID.rawValue], in: db)
        return ActionReceipt(operationIDs: [], undo: .setReminder(ref, dueAt: MailStore.storeDate(millis: previous.dueAt),
                                                                  condition: previous.condition))
    }

    static func anchor(tid: Int64, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT gmail_message_id FROM messages WHERE tid = ? AND is_draft = 0
            ORDER BY (in_trash = 0 AND in_spam = 0) DESC, internal_date DESC, mid DESC LIMIT 1
            """, arguments: [tid])
    }
}
