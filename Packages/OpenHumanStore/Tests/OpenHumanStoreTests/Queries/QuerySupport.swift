import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Synchronization
import Testing
@testable import OpenHumanStore

enum OpenHumanStoreTestingBridge {
    static func seeded(count: Int) throws -> (MailStore, AccountID) {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        let msgs = (0..<count).map { MessageUpsert.fixture("m\($0)", minutes: $0 / 2, labels: ["INBOX"], subject: "S\($0)") }
        _ = try store.upsertMessages(msgs, account: account, generation: 1)
        return (store, account)
    }
}

extension MailStore {
    @discardableResult
    func insertDraft(account: AccountID, id: String = UUID().uuidString, tid: Int64? = nil, gmailThread: String? = nil,
                     gmailDraft: String? = nil, state: String = "editing", review: String = "none", origin: String = "user",
                     subject: String = "Re: hi", to: String = "[{\"e\":\"bob@example.com\",\"n\":\"Bob\"}]",
                     updatedAt: Int64 = 1_790_000_000_000, local: Int = 1, synced: Int = 0,
                     conflict: String? = nil, note: String? = nil) throws -> DraftID {
        try write { db in
            try db.execute(sql: """
                INSERT INTO drafts (draft_uuid, account_id, gmail_draft_id, tid, gmail_thread_id, from_email, to_json, subject,
                                    body_html, origin, review_state, state, local_version, synced_version, remote_conflict_json,
                                    agent_note, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'me@example.com', ?, ?, '<p>x</p>', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, account.rawValue, gmailDraft, tid, gmailThread, to, subject, origin, review, state, local,
                                 synced, conflict, note, updatedAt, updatedAt])
        }
        return DraftID(id)
    }

    func threadID(_ account: AccountID, _ gmailThread: String) throws -> Int64 {
        try #require(try thread(account: account, gmailThreadID: GmailThreadID(gmailThread))).rowID.rawValue
    }
}

func queryPlan(_ store: MailStore, _ sql: String, _ arguments: StatementArguments = StatementArguments()) throws -> String {
    try store.read { db in
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] as String }.joined(separator: "\n")
    }
}

func plans(_ store: MailStore, _ body: @Sendable (Database) throws -> Void) throws -> [(sql: String, plan: String)] {
    try store.read { db in
        let seen = Mutex<[String]>([])
        db.trace(options: .statement) { event in
            if case let .statement(statement) = event {
                seen.withLock { $0.append(statement.sql) }
            }
        }
        try body(db)
        db.trace(options: [], nil)
        return try seen.withLock { $0 }
            .filter { !$0.hasPrefix("EXPLAIN") && !$0.hasPrefix("PRAGMA") }
            .map { sql in
                let statement = try db.makeStatement(sql: "EXPLAIN QUERY PLAN " + sql)
                statement.setUncheckedArguments(StatementArguments(Array(repeating: 1, count: 40)))
                return (sql, try Row.fetchAll(statement).map { $0["detail"] as String }.joined(separator: "\n"))
            }
    }
}

func expectIndexed(_ plans: [(sql: String, plan: String)], allowTempBTree: Bool = false,
                   sourceLocation: SourceLocation = #_sourceLocation) {
    let big: Set<String> = ["threads", "t", "messages", "m", "thread_labels", "tl", "message_bodies", "message_search_docs",
                            "attachments", "contacts"]
    for (sql, plan) in plans {
        for line in plan.split(separator: "\n") {
            let text = line.drop { "|-` ".contains($0) }
            let words = text.split(separator: " ")
            if words.first == "SCAN", words.count > 1 {
                #expect(!big.contains(String(words[1])), "full scan of \(words[1]):\n\(sql)\n\(plan)", sourceLocation: sourceLocation)
            }
        }
        if !allowTempBTree { #expect(!plan.contains("TEMP B-TREE"), "sort step:\n\(sql)\n\(plan)", sourceLocation: sourceLocation) }
    }
}
