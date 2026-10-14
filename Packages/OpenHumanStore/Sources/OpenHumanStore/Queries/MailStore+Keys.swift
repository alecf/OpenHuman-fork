import Foundation
import GRDB
import OpenHumanCore

extension MailStore {
    public func messageKey(_ id: MessageRowID) throws -> (ref: ThreadRef, gmailMessageID: GmailMessageID)? {
        try read { db in try Self.messageKey(mid: id.rawValue, in: db) }
    }

    public func attachmentKey(_ aid: Int64) throws -> (ref: ThreadRef, gmailMessageID: GmailMessageID)? {
        try read { db in try Self.attachmentKey(aid: aid, in: db) }
    }

    static func messageKey(mid: Int64, in db: Database) throws -> (ref: ThreadRef, gmailMessageID: GmailMessageID)? {
        try Row.fetchOne(db, sql: """
            SELECT m.account_id, m.gmail_message_id, t.tid, t.gmail_thread_id
            FROM messages m JOIN threads t ON t.tid = m.tid
            WHERE m.mid = ?
            """, arguments: [mid]).map(key)
    }

    static func attachmentKey(aid: Int64, in db: Database) throws -> (ref: ThreadRef, gmailMessageID: GmailMessageID)? {
        try Row.fetchOne(db, sql: """
            SELECT m.account_id, m.gmail_message_id, t.tid, t.gmail_thread_id
            FROM attachments a JOIN messages m ON m.mid = a.mid JOIN threads t ON t.tid = m.tid
            WHERE a.aid = ?
            """, arguments: [aid]).map(key)
    }

    private static func key(_ row: Row) -> (ref: ThreadRef, gmailMessageID: GmailMessageID) {
        let ref = ThreadRef(accountID: AccountID(rawValue: row["account_id"]), rowID: ThreadRowID(rawValue: row["tid"]),
                            gmailThreadID: GmailThreadID(row["gmail_thread_id"] as String))
        return (ref, GmailMessageID(row["gmail_message_id"] as String))
    }
}
