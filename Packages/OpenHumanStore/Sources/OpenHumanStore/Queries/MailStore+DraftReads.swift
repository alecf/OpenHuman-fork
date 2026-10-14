import Foundation
import GRDB
import OpenHumanCore

private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

extension MailStore {
    public func drafts(account: AccountID?, states: Set<DraftState>, limit: Int) throws -> [DraftListItem] {
        try read { db in try Self.draftItems(account: account, states: states, limit: limit, in: db) }
    }

    public func draft(_ id: DraftID) throws -> DraftListItem? {
        try read { db in try Self.draftItem(id, in: db) }
    }

    public func draft(account: AccountID, gmailDraftID: GmailDraftID) throws -> DraftListItem? {
        try read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM drafts WHERE account_id = ? AND gmail_draft_id = ?",
                             arguments: [account.rawValue, gmailDraftID.rawValue]).map(Self.draftItem)
        }
    }

    public func reviewQueue(account: AccountID?) throws -> [DraftListItem] {
        try read { db in try Self.reviewQueueItems(account: account, in: db) }
    }

    static func draftItems(account: AccountID?, states: Set<DraftState>, limit: Int, in db: Database) throws -> [DraftListItem] {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []
        if let account { clauses.append("account_id = ?"); args.append(account.rawValue) }
        if !states.isEmpty {
            clauses.append("state IN (\(Array(repeating: "?", count: states.count).joined(separator: ", ")))")
            args += states.map(\.rawValue).sorted()
        }
        args.append(max(limit, 0))
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try Row.fetchAll(db, sql: "SELECT * FROM drafts \(filter) ORDER BY updated_at DESC, draft_uuid LIMIT ?",
                                arguments: StatementArguments(args.map { $0.databaseValue })).map(draftItem)
    }

    static func draftItem(_ id: DraftID, in db: Database) throws -> DraftListItem? {
        try Row.fetchOne(db, sql: "SELECT * FROM drafts WHERE draft_uuid = ?", arguments: [id.rawValue]).map(draftItem)
    }

    static func reviewQueueItems(account: AccountID?, in db: Database) throws -> [DraftListItem] {
        let rows: [Row]
        if let account {
            rows = try Row.fetchAll(db, sql: """
                SELECT * FROM drafts WHERE review_state = 'pending' AND account_id = ? AND state NOT IN ('sent', 'discarded')
                ORDER BY updated_at, draft_uuid
                """, arguments: [account.rawValue])
        } else {
            rows = try Row.fetchAll(db, sql: """
                SELECT * FROM drafts WHERE review_state = 'pending' AND state NOT IN ('sent', 'discarded')
                ORDER BY updated_at, draft_uuid
                """)
        }
        return rows.map(draftItem)
    }

    static func draftItem(_ r: Row) -> DraftListItem {
        let account = AccountID(r["account_id"])
        let tid: Int64? = r["tid"]
        let gmailThread: String? = r["gmail_thread_id"]
        var thread: ThreadRef?
        if let tid, let gmailThread {
            thread = ThreadRef(accountID: account, rowID: ThreadRowID(rawValue: tid), gmailThreadID: GmailThreadID(gmailThread))
        }
        let from: String? = r["from_email"]
        let content = DraftContent(
            from: from.map { EmailAddress(email: $0) },
            to: DraftRowCodec.decodeAddresses(r["to_json"]), cc: DraftRowCodec.decodeAddresses(r["cc_json"]),
            bcc: DraftRowCodec.decodeAddresses(r["bcc_json"]), subject: r["subject"], bodyHTML: r["body_html"],
            bodyText: r["body_text"], attachments: DraftRowCodec.decodeAttachments(r["attachments_json"]))
        let snapshot = (r["agent_snapshot_json"] as String?).flatMap {
            try? JSONDecoder().decode(DraftContent.self, from: Data($0.utf8))
        }
        let gmailDraft: String? = r["gmail_draft_id"], replyTo: String? = r["reply_to_gmail_message_id"]
        let gmailMessage: String? = r["gmail_message_id"]
        let sendAt: Int64? = r["send_at"]
        let local: Int = r["local_version"], synced: Int = r["synced_version"]
        return DraftListItem(
            id: DraftID(r["draft_uuid"] as String), accountID: account, gmailDraftID: gmailDraft.map { GmailDraftID($0) },
            thread: thread, composeMode: ComposeMode(rawValue: r["compose_mode"]) ?? .new,
            replyToMessageID: replyTo.map { GmailMessageID($0) }, content: content,
            origin: DraftOrigin(rawValue: r["origin"]) ?? .user,
            reviewState: DraftReviewState(rawValue: r["review_state"]) ?? .none,
            state: DraftState(rawValue: r["state"]) ?? .editing, sendAt: sendAt.map(date), isDirty: local > synced,
            hasRemoteConflict: (r["remote_conflict_json"] as String?) != nil, agentNote: r["agent_note"],
            agentSnapshot: snapshot, lastError: r["last_error"], updatedAt: date(r["updated_at"]),
            localVersion: local, gmailMessageID: gmailMessage.map { GmailMessageID($0) },
            gmailThreadID: gmailThread.map { GmailThreadID($0) },
            extraHeaders: DraftRowCodec.decodeHeaders(r["extra_headers_json"]))
    }

    private struct WireVariable: Decodable {
        var name: String
        var `default`: String?
        var defaultValue: String?
    }

    public func snippets(account: AccountID?) throws -> [SnippetItem] {
        try read { db in try Self.snippetItems(account: account, in: db) }
    }

    static func snippetItems(account: AccountID?, in db: Database) throws -> [SnippetItem] {
        let rows: [Row]
        if let account {
            rows = try Row.fetchAll(db, sql: """
                SELECT * FROM snippets WHERE account_id = ? OR account_id IS NULL ORDER BY name COLLATE NOCASE, snippet_id
                """, arguments: [account.rawValue])
        } else {
            rows = try Row.fetchAll(db, sql: "SELECT * FROM snippets ORDER BY name COLLATE NOCASE, snippet_id")
        }
        return rows.map { r in
            let variables = ((r["variables_json"] as String).data(using: .utf8))
                .flatMap { try? JSONDecoder().decode([WireVariable].self, from: $0) } ?? []
            let owner: Int64? = r["account_id"]
            return SnippetItem(
                id: r["snippet_id"], accountID: owner.map { AccountID($0) }, name: r["name"], shortcut: r["shortcut"],
                subject: r["subject"], bodyHTML: r["body_html"],
                variables: variables.map { SnippetVariable(name: $0.name, defaultValue: $0.default ?? $0.defaultValue) },
                useCount: r["use_count"],
                to: DraftRowCodec.decodeAddresses(r["to_json"] ?? "[]"),
                cc: DraftRowCodec.decodeAddresses(r["cc_json"] ?? "[]"),
                bcc: DraftRowCodec.decodeAddresses(r["bcc_json"] ?? "[]"),
                attachments: SnippetFiles.decode(r["attachments_json"] ?? "[]"))
        }
    }

    public func contactSuggestions(account: AccountID, prefix: String, limit: Int) throws -> [ContactSuggestion] {
        try read { db in
            let p = Self.likeEscaped(prefix.trimmingCharacters(in: .whitespacesAndNewlines))
            return try Row.fetchAll(db, sql: """
                SELECT email, name, sent_count, received_count FROM contacts
                WHERE account_id = ?1
                  AND (?2 = '' OR email LIKE ?2 || '%' ESCAPE '\\' OR name LIKE ?2 || '%' ESCAPE '\\'
                       OR name LIKE '% ' || ?2 || '%' ESCAPE '\\')
                ORDER BY sent_count DESC, received_count DESC, email
                LIMIT ?3
                """, arguments: [account.rawValue, p, max(limit, 0)]).map { r in
                ContactSuggestion(name: r["name"], email: r["email"],
                                  score: Double(r["sent_count"] as Int) + Double(r["received_count"] as Int) / 1000)
            }
        }
    }

    static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    public func recentThreads(involving email: String, account: AccountID, limit: Int) throws -> [ThreadListItem] {
        try read { db in
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { return [] }
            let n = min(max(limit, 0), Self.maxPageLimit)
            let pattern = "%\"e\":\"" + Self.likeEscaped(address) + "\"%"
            let tids = try Int64.fetchAll(db, sql: """
                SELECT tid FROM (
                    SELECT tid, internal_date FROM (
                        SELECT tid, internal_date FROM messages
                        WHERE account_id = ?1 AND from_email = ?2 AND in_trash = 0 AND in_spam = 0 AND is_draft = 0
                        ORDER BY internal_date DESC LIMIT 500)
                    UNION ALL
                    SELECT tid, internal_date FROM (
                        SELECT tid, internal_date, to_json, cc_json FROM messages
                        WHERE account_id = ?1 AND is_sent = 1 ORDER BY internal_date DESC LIMIT 2000)
                    WHERE to_json LIKE ?3 ESCAPE '\\' OR cc_json LIKE ?3 ESCAPE '\\')
                GROUP BY tid ORDER BY max(internal_date) DESC, tid DESC LIMIT ?4
                """, arguments: [account.rawValue, address, pattern, n])
            return try tids.compactMap { try Self.threadItem(tid: $0, in: db) }
        }
    }
}
