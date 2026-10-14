import Foundation
import GRDB
import OpenHumanCore

extension MailStore: SemanticIndexReading {
    static let semanticReadChunk = 500

    public func storeEpoch() throws -> String {
        try read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT created_at, created_by_version FROM schema_info WHERE id = 1")
            else { throw StoreError.integrity("schema_info") }
            let created: Int64 = row["created_at"]
            let version: String = row["created_by_version"]
            return "\(created)-\(version)"
        }
    }

    public func indexableMessages(afterMessage: MessageRowID?, limit: Int) throws -> [IndexableMessage] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT mid, account_id, gmail_message_id, tid, internal_date, body_state, is_draft, in_spam
                FROM messages
                WHERE mid > ? AND account_id IN (SELECT account_id FROM accounts WHERE status <> 'removing')
                ORDER BY mid
                LIMIT ?
                """, arguments: [afterMessage?.rawValue ?? 0, max(limit, 0)]).map(Self.indexable)
        }
    }

    public func indexableMessages(_ ids: [MessageRowID]) throws -> [IndexableMessage] {
        try read { db in
            try Self.chunks(ids).flatMap { chunk in
                try Row.fetchAll(db, sql: """
                    SELECT mid, account_id, gmail_message_id, tid, internal_date, body_state, is_draft, in_spam
                    FROM messages
                    WHERE mid IN (SELECT value FROM json_each(?))
                      AND account_id IN (SELECT account_id FROM accounts WHERE status <> 'removing')
                    ORDER BY mid
                    """, arguments: [Self.jsonIDs(chunk)]).map(Self.indexable)
            }
        }
    }

    public func messageIDsAwaitingBodies(account: AccountID) throws -> [MessageRowID] {
        try read { db in
            try Int64.fetchAll(db, sql: """
                SELECT mid FROM messages WHERE account_id = ? AND body_state < 2
                """, arguments: [account.rawValue]).map { MessageRowID(rawValue: $0) }
        }
    }

    public func indexableDocuments(_ ids: [MessageRowID]) throws -> [IndexableDocument] {
        try read { db in
            var documents: [IndexableDocument] = []
            for chunk in Self.chunks(ids) {
                let json = Self.jsonIDs(chunk)
                var names: [Int64: [String]] = [:]
                for row in try Row.fetchAll(db, sql: """
                    SELECT mid, filename FROM attachments
                    WHERE mid IN (SELECT value FROM json_each(?)) AND is_inline = 0 AND filename <> ''
                    ORDER BY mid, aid
                    """, arguments: [json]) {
                    let mid: Int64 = row["mid"]
                    if names[mid, default: []].count < 10 { names[mid, default: []].append(row["filename"]) }
                }
                for row in try Row.fetchAll(db, sql: """
                    SELECT m.mid, m.subject, m.from_name, m.snippet, m.body_state, d.body AS doc_body
                    FROM messages m LEFT JOIN message_search_docs d ON d.mid = m.mid
                    WHERE m.mid IN (SELECT value FROM json_each(?))
                    ORDER BY m.mid
                    """, arguments: [json]) {
                    let mid: Int64 = row["mid"]
                    let docBody: String? = row["doc_body"]
                    let snippet: String = row["snippet"]
                    let body = (docBody?.isEmpty == false ? docBody : nil) ?? snippet
                    documents.append(IndexableDocument(message: MessageRowID(rawValue: mid), subject: row["subject"],
                                                       fromName: row["from_name"], body: body,
                                                       attachmentNames: names[mid] ?? [],
                                                       hasStoredBody: (row["body_state"] as Int) == BodyState.stored.rawValue))
                }
            }
            return documents
        }
    }

    public func messageIdentities(_ ids: [MessageRowID]) throws -> [MessageRowID: GmailMessageID] {
        try read { db in
            var identities: [MessageRowID: GmailMessageID] = [:]
            for chunk in Self.chunks(ids) {
                for row in try Row.fetchAll(db, sql: """
                    SELECT mid, gmail_message_id FROM messages WHERE mid IN (SELECT value FROM json_each(?))
                    """, arguments: [Self.jsonIDs(chunk)]) {
                    identities[MessageRowID(rawValue: row["mid"])] = GmailMessageID(row["gmail_message_id"] as String)
                }
            }
            return identities
        }
    }

    public func bodyDownloadStatus(account: AccountID) throws -> BodyDownloadStatus {
        guard try setting(.downloadBodies, scope: .global) else { return .off }
        let cap: Int? = try setting(.bodyMaxMessages, scope: .global)
        return try read { db in
            let complete = try Bool.fetchOne(db, sql: "SELECT body_backfill_complete FROM sync_state WHERE account_id = ?",
                                             arguments: [account.rawValue]) ?? false
            if let cap {
                let stored = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE account_id = ? AND body_state = 2",
                                              arguments: [account.rawValue]) ?? 0
                if stored >= cap { return .capped }
            }
            return complete ? .complete : .downloading
        }
    }

    public func indexableCount(account: AccountID) throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE account_id = ? AND is_draft = 0 AND in_spam = 0",
                             arguments: [account.rawValue]) ?? 0
        }
    }

    private static func indexable(_ row: Row) -> IndexableMessage {
        let at: Int64 = row["internal_date"]
        return IndexableMessage(message: MessageRowID(rawValue: row["mid"]), account: AccountID(row["account_id"] as Int64),
                                gmailMessageID: GmailMessageID(row["gmail_message_id"] as String),
                                thread: ThreadRowID(rawValue: row["tid"]),
                                internalDate: Date(timeIntervalSince1970: Double(at) / 1000),
                                bodyState: BodyState(rawValue: row["body_state"]) ?? .none,
                                isDraft: row["is_draft"], inSpam: row["in_spam"])
    }

    private static func chunks(_ ids: [MessageRowID]) -> [[MessageRowID]] {
        stride(from: 0, to: ids.count, by: semanticReadChunk).map { Array(ids[$0..<min($0 + semanticReadChunk, ids.count)]) }
    }

    private static func jsonIDs(_ ids: [MessageRowID]) -> String {
        "[" + ids.map { String($0.rawValue) }.joined(separator: ",") + "]"
    }
}
