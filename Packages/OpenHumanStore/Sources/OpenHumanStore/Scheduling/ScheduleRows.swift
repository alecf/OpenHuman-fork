import Foundation
import GRDB
import OpenHumanCore

enum ScheduleRows {
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    static func ref(account: Int64, tid: Int64, gmailThreadID: String) -> ThreadRef {
        ThreadRef(accountID: AccountID(account), rowID: ThreadRowID(rawValue: tid), gmailThreadID: GmailThreadID(gmailThreadID))
    }

    static func reminderInfo(_ r: Row) -> ReminderInfo {
        ReminderInfo(id: r["reminder_id"], dueAt: date(r["due_at"]),
                     condition: ReminderCondition(rawValue: r["condition"]) ?? .always)
    }

    static func activeReminders(account: AccountID?, limit: Int, in db: Database) throws -> [ReminderSummary] {
        var args: [any DatabaseValueConvertible] = []
        var filter = ""
        if let account { filter = "AND r.account_id = ?"; args.append(account.rawValue) }
        args.append(max(limit, 0))
        return try Row.fetchAll(db, sql: """
            SELECT r.reminder_id, r.tid, r.account_id, r.gmail_thread_id, r.due_at, r.condition, t.subject
            FROM reminders r JOIN threads t ON t.tid = r.tid
            WHERE r.state = 'active' \(filter) ORDER BY r.due_at, r.reminder_id LIMIT ?
            """, arguments: StatementArguments(args.map { $0.databaseValue })).map { r in
            ReminderSummary(ref: ref(account: r["account_id"], tid: r["tid"], gmailThreadID: r["gmail_thread_id"]),
                            reminder: reminderInfo(r), subject: r["subject"])
        }
    }

    static func draftListItem(_ r: Row) -> DraftListItem { MailStore.draftItem(r) }
}
