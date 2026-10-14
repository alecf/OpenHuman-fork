import Foundation
import GRDB
import OpenHumanCore

private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

extension MailStore {
    static func snoozeInfo(tid: Int64, in db: Database) throws -> SnoozeInfo? {
        guard let r = try Row.fetchOne(db, sql: "SELECT * FROM snoozes WHERE tid = ?", arguments: [tid]) else { return nil }
        let wake: Int64? = r["wake_at"]
        return SnoozeInfo(wakeAt: wake.map(date), labelName: r["label_name"], stampLabelCount: r["stamp_label_count"])
    }

    static func reminderInfo(tid: Int64, in db: Database) throws -> ReminderInfo? {
        try Row.fetchOne(db, sql: "SELECT * FROM reminders WHERE tid = ? AND state = 'active'", arguments: [tid]).map(reminderInfo)
    }

    static func reminderInfo(_ r: Row) -> ReminderInfo {
        ReminderInfo(id: r["reminder_id"], dueAt: date(r["due_at"]),
                     condition: ReminderCondition(rawValue: r["condition"]) ?? .always)
    }

    static func reminderSummaries(account: AccountID?, limit: Int, in db: Database) throws -> [ReminderSummary] {
        var args: [any DatabaseValueConvertible] = []
        var filter = ""
        if let account { filter = "AND r.account_id = ?"; args.append(account.rawValue) }
        args.append(max(limit, 0))
        return try Row.fetchAll(db, sql: """
            SELECT r.*, t.subject FROM reminders r JOIN threads t ON t.tid = r.tid
            WHERE r.state = 'active' \(filter) ORDER BY r.due_at, r.reminder_id LIMIT ?
            """, arguments: StatementArguments(args.map { $0.databaseValue })).map { r in
            ReminderSummary(
                ref: ThreadRef(accountID: AccountID(r["account_id"]), rowID: ThreadRowID(rawValue: r["tid"]),
                               gmailThreadID: GmailThreadID(r["gmail_thread_id"])),
                reminder: reminderInfo(r), subject: r["subject"])
        }
    }
}
