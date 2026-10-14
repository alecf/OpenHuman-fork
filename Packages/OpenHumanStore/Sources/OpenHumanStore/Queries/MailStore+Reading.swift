import Foundation
import GRDB
import OpenHumanCore

private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

extension MailStore: MailReading {
    public func accounts() throws -> [AccountItem] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM accounts ORDER BY position, account_id").map(Self.accountItem)
        }
    }

    public func account(matching emailOrAlias: String) throws -> AccountItem? {
        try read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM accounts WHERE email = ?1 OR alias = ?1",
                             arguments: [emailOrAlias]).map(Self.accountItem)
        }
    }

    public func labels(account: AccountID) throws -> [LabelItem] {
        try read { db in try Self.labelItems(account: account.rawValue, in: db) }
    }

    public func label(account: AccountID, key: String) throws -> LabelItem? {
        try read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM labels WHERE account_id = ? AND key = ?",
                             arguments: [account.rawValue, key]).map(Self.labelItem)
        }
    }

    public func splits(account: AccountID) throws -> [SplitItem] {
        try read { db in try Self.splitItems(account: account.rawValue, in: db) }
    }

    public func threadPage(view: MailboxView, after: ThreadCursor?, limit: Int) throws -> ThreadPage {
        try read { db in try Self.withCategories(Self.page(view: view, after: after, limit: limit, in: db), in: db) }
    }

    public func thread(_ ref: ThreadRef) throws -> ThreadListItem? {
        try read { db in try Self.threadItem(tid: ref.rowID.rawValue, in: db) }
    }

    public func thread(account: AccountID, gmailThreadID: GmailThreadID) throws -> ThreadRef? {
        try read { db in
            try Row.fetchOne(db, sql: "SELECT tid FROM threads WHERE account_id = ? AND gmail_thread_id = ?",
                             arguments: [account.rawValue, gmailThreadID.rawValue]).map {
                ThreadRef(accountID: account, rowID: ThreadRowID(rawValue: $0["tid"]), gmailThreadID: gmailThreadID)
            }
        }
    }

    public func threadDetail(_ id: ThreadRowID) throws -> ThreadDetail? {
        let dir = attachmentsDirectory
        return try read { db in try Self.detail(id, attachmentsDirectory: dir, in: db) }
    }

    public func message(account: AccountID, gmailMessageID: GmailMessageID) throws -> MessageItem? {
        let dir = attachmentsDirectory
        return try read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE account_id = ? AND gmail_message_id = ?",
                                             arguments: [account.rawValue, gmailMessageID.rawValue]) else { return nil }
            let mid: Int64 = row["mid"]
            return Self.messageItem(row, attachments: try Self.attachmentItems(mids: [mid], directory: dir, in: db)[mid] ?? [])
        }
    }

    public func body(_ id: MessageRowID) throws -> MessageBody? {
        let dir = attachmentsDirectory
        return try read { db in try Self.bodyItem(id, attachmentsDirectory: dir, in: db) }
    }

    public func attachments(message: MessageRowID) throws -> [AttachmentItem] {
        let dir = attachmentsDirectory
        return try read { db in try Self.attachmentItems(mids: [message.rawValue], directory: dir, in: db)[message.rawValue] ?? [] }
    }

    public func counts(account: AccountID) throws -> MailboxCounts {
        try read { db in try Self.mailboxCounts(account: account, in: db) }
    }

    public func syncStatus(account: AccountID) throws -> SyncStatus {
        try read { db in try Self.syncStatus(account: account, lease: try Self.leaseInfo(account: account.rawValue, in: db), in: db) }
    }

    public func operations(account: AccountID?, statuses: Set<OperationStatus>, limit: Int) throws -> [OperationItem] {
        try read { db in try Self.operationItems(account: account, statuses: statuses, limit: limit, in: db) }
    }

    public func operation(_ id: OperationID) throws -> OperationItem? {
        try read { db in try Self.operationItem(id: id.rawValue, in: db) }
    }

    public func syncLog(account: AccountID, limit: Int) throws -> [SyncLogEntry] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM sync_log WHERE account_id = ? ORDER BY started_at DESC, log_id DESC LIMIT ?
                """, arguments: [account.rawValue, max(limit, 0)]).map { r in
                let finished: Int64? = r["finished_at"]
                return SyncLogEntry(accountID: account, startedAt: date(r["started_at"]), finishedAt: finished.map(date),
                                    kind: r["kind"], outcome: r["outcome"], quotaUnits: r["quota_units"],
                                    requests: r["requests"], added: r["added"], changed: r["changed"],
                                    deleted: r["deleted"], errorCode: r["error_code"], detail: r["detail"])
            }
        }
    }
}

extension MailStore {
    var attachmentsDirectory: URL { location.attachmentsDirectory }

    static func operationItems(account: AccountID?, statuses: Set<OperationStatus>, limit: Int, in db: Database) throws -> [OperationItem] {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []
        if let account { clauses.append("account_id = ?"); args.append(account.rawValue) }
        if !statuses.isEmpty {
            clauses.append("status IN (\(Array(repeating: "?", count: statuses.count).joined(separator: ", ")))")
            args += statuses.map(\.rawValue).sorted()
        }
        args.append(max(limit, 0))
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try Row.fetchAll(db, sql: "SELECT * FROM pending_operations \(filter) ORDER BY op_id LIMIT ?",
                                arguments: StatementArguments(args.map { $0.databaseValue })).map(operationItem)
    }

    static func mailboxCounts(account: AccountID, in db: Database) throws -> MailboxCounts {
        var byLabel: [LabelRowID: LabelCount] = [:]
        var inboxUnread = 0
        for r in try Row.fetchAll(db, sql: "SELECT label_rid, key, total_threads, unread_threads FROM labels WHERE account_id = ?",
                                  arguments: [account.rawValue]) {
            byLabel[LabelRowID(rawValue: r["label_rid"])] = LabelCount(total: r["total_threads"], unread: r["unread_threads"])
            if (r["key"] as String) == "INBOX" { inboxUnread = r["unread_threads"] }
        }
        var splitUnread: [SplitID: Int] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT s.split_id, l.unread_threads FROM splits s JOIN labels l ON l.label_rid = s.label_rid
            WHERE s.account_id = ? AND s.enabled = 1
            """, arguments: [account.rawValue]) {
            splitUnread[SplitID(r["split_id"] as String)] = r["unread_threads"]
        }
        let drafts = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM drafts WHERE account_id = ? AND state IN ('editing', 'failed')
            """, arguments: [account.rawValue]) ?? 0
        let review = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM drafts WHERE account_id = ? AND review_state = 'pending' AND state IN ('editing', 'failed', 'scheduled')
            """, arguments: [account.rawValue]) ?? 0
        let failed = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM pending_operations WHERE account_id = ? AND status = 'failed'
            """, arguments: [account.rawValue]) ?? 0
        return MailboxCounts(accountID: account, byLabel: byLabel, inboxUnread: inboxUnread, splitUnread: splitUnread,
                             draftsCount: drafts, pendingReviewCount: review, failedOperationCount: failed)
    }

    static func syncStatus(account: AccountID, lease: LeaseInfo?, in db: Database) throws -> SyncStatus {
        guard let r = try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE account_id = ?",
                                       arguments: [account.rawValue]) else {
            throw StoreError.notFound("sync_state \(account.rawValue)")
        }
        let history: Int64? = r["history_id"]
        let lastSuccess: Int64? = r["last_success_at"], lastAttempt: Int64? = r["last_attempt_at"]
        let oldest: Int64? = r["backfill_oldest_at"]
        let pending = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM pending_operations WHERE account_id = ? AND status IN ('pending', 'in_flight')
            """, arguments: [account.rawValue]) ?? 0
        let failed = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM pending_operations WHERE account_id = ? AND status = 'failed'
            """, arguments: [account.rawValue]) ?? 0
        return SyncStatus(
            accountID: account, phase: SyncPhase(rawValue: r["phase"]) ?? .new,
            historyID: history.map { HistoryID(UInt64($0)) }, lastSuccessAt: lastSuccess.map(date),
            lastAttemptAt: lastAttempt.map(date), backfillOldest: oldest.map(date),
            backfillComplete: r["backfill_complete"], consecutiveFailures: r["consecutive_failures"],
            lastError: r["last_error_message"], owner: lease, pendingOperations: pending, failedOperations: failed,
            generation: r["generation"])
    }

    static func splitItems(account: Int64, in db: Database) throws -> [SplitItem] {
        try Row.fetchAll(db, sql: """
            SELECT s.*, l.unread_threads, l.total_threads FROM splits s JOIN labels l ON l.label_rid = s.label_rid
            WHERE s.account_id = ? ORDER BY s.position, s.created_at, s.split_id
            """, arguments: [account]).compactMap { r in
            guard let rule = try? JSONDecoder().decode(SplitRule.self, from: Data((r["rule_json"] as String).utf8)) else { return nil }
            let role: String? = r["role"]
            return SplitItem(id: SplitID(r["split_id"] as String), accountID: AccountID(r["account_id"]),
                             labelRowID: LabelRowID(rawValue: r["label_rid"]), name: r["name"], position: r["position"],
                             ruleText: r["rule_text"], rule: rule, enabled: r["enabled"],
                             unreadThreads: r["unread_threads"], totalThreads: r["total_threads"],
                             isImportanceSplit: role == "important")
        }
    }
    static func accountItem(_ r: Row) -> AccountItem {
        let sendAs = ((r["send_as_json"] as String).data(using: .utf8))
            .flatMap { try? JSONDecoder().decode([SendAsIdentity].self, from: $0) } ?? []
        return AccountItem(id: AccountID(r["account_id"]), email: r["email"], displayName: r["display_name"],
                           alias: r["alias"], color: r["color"], position: r["position"],
                           status: AccountStatus(rawValue: r["status"]) ?? .active, sendAs: sendAs,
                           grantedScopes: (r["granted_scopes"] as String).split(separator: " ").map(String.init))
    }

    static func labelItem(_ r: Row) -> LabelItem {
        LabelItem(id: LabelRowID(rawValue: r["label_rid"]), accountID: AccountID(r["account_id"]), key: r["key"],
                  kind: LabelKind(rawValue: r["kind"]) ?? .user, name: r["name"], displayName: r["display_name"],
                  colorBackground: r["color_bg"], colorText: r["color_text"], isHidden: r["is_hidden"],
                  position: r["position"], totalThreads: r["total_threads"], unreadThreads: r["unread_threads"])
    }

    static func labelItems(account: Int64, in db: Database) throws -> [LabelItem] {
        try Row.fetchAll(db, sql: """
            SELECT * FROM labels WHERE account_id = ?
            ORDER BY CASE kind WHEN 'system' THEN 0 WHEN 'category' THEN 1 WHEN 'user' THEN 2
                               WHEN 'virtual' THEN 3 ELSE 4 END,
                     CASE WHEN kind = 'user' THEN name END COLLATE NOCASE, position, label_rid
            """, arguments: [account]).map(labelItem)
    }

    static let systemKeys: [SystemMailbox: String] = [
        .inbox: "INBOX", .starred: "STARRED", .important: "IMPORTANT", .unread: "UNREAD", .sent: "SENT",
        .drafts: "DRAFT", .allMail: "oh:allmail", .trash: "TRASH", .spam: "SPAM", .snoozed: "oh:snoozed",
        .scheduled: "oh:scheduled", .reminders: "oh:reminders", .waiting: "oh:waiting",
        .done: "oh:allmail",
    ]

    static let doneFilter = "AND t.in_inbox = 0 AND t.message_count > 0"

    static func viewFilter(_ view: MailboxView) -> String {
        if case .system(_, .done) = view { return doneFilter }
        return ""
    }

    static func resolve(_ view: MailboxView, in db: Database) throws -> (account: Int64, rid: Int64, direction: Int)? {
        let account: Int64
        let sql: String
        let arg: String
        switch view {
        case let .system(a, box):
            account = a.rawValue; sql = "SELECT label_rid, sort_direction FROM labels WHERE account_id = ? AND key = ?"
            arg = systemKeys[box]!
        case let .label(a, id):
            account = a.rawValue; sql = "SELECT label_rid, sort_direction FROM labels WHERE account_id = ? AND key = ?"
            arg = id.rawValue
        case let .split(a, id):
            account = a.rawValue
            sql = """
                SELECT l.label_rid, l.sort_direction FROM splits s JOIN labels l ON l.label_rid = s.label_rid
                WHERE s.account_id = ? AND s.split_id = ?
                """
            arg = id.rawValue
        case let .splitOther(a):
            account = a.rawValue; sql = "SELECT label_rid, sort_direction FROM labels WHERE account_id = ? AND key = ?"
            arg = "oh:split:other"
        case .unified:
            throw StoreError.unsupportedView("unified")
        }
        guard let r = try Row.fetchOne(db, sql: sql, arguments: [account, arg]) else { return nil }
        return (account, r["label_rid"], r["sort_direction"])
    }

    static let listColumns = """
        t.tid, t.account_id, t.gmail_thread_id, t.subject, t.snippet, t.participants_display, t.participants_json,
        t.message_count, t.unread_count, t.draft_count, t.attachment_count, t.is_starred, t.is_important,
        t.user_label_rids, t.last_message_at, t.snoozed_until, t.reminder_at, t.scheduled_send_at,
        EXISTS (SELECT 1 FROM pending_op_messages pom JOIN messages m ON m.mid = pom.mid
                JOIN pending_operations o ON o.op_id = pom.op_id
                WHERE m.tid = t.tid AND o.status IN ('pending', 'in_flight')) AS has_pending,
        t.importance, t.split_chip_rids
        """
    static let listColumnCount = 21

    static func listItem(_ r: Row, sortAt: Int64, unread: Bool, decoder: JSONDecoder) -> ThreadListItem {
        let tid: Int64 = r[0]
        let participantsJSON: String = r[6]
        let people = participantsJSON == "[]" ? [] : ((try? decoder.decode([WirePerson].self, from: Data(participantsJSON.utf8))) ?? [])
        let rids = (r[13] as String).split(separator: ",").compactMap { Int64($0) }
        let snoozed: Int64? = r[15], reminder: Int64? = r[16], scheduled: Int64? = r[17]
        return ThreadListItem(
            id: ThreadRowID(rawValue: tid),
            ref: ThreadRef(accountID: AccountID(r[1] as Int64), rowID: ThreadRowID(rawValue: tid),
                           gmailThreadID: GmailThreadID(r[2] as String)),
            subject: r[3], snippet: r[4], participantsDisplay: r[5],
            participants: people.map { ParticipantSummary(name: $0.n, email: $0.e, isMe: $0.me != 0, hasUnread: $0.u != 0) },
            messageCount: r[7], unreadCount: r[8], isUnread: unread,
            draftCount: r[9], attachmentCount: r[10], isStarred: r[11],
            isImportant: r[12], userLabelIDs: rids.map { LabelRowID(rawValue: $0) },
            lastMessageAt: date(r[14]), sortAt: date(sortAt), snoozedUntil: snoozed.map(date),
            reminderAt: reminder.map(date), scheduledSendAt: scheduled.map(date),
            hasPendingChanges: r[18], importance: ThreadImportance(rawValue: r[19]) ?? .normal,
            splitChipIDs: (r[20] as String).split(separator: ",").compactMap { Int64($0) }.map { LabelRowID(rawValue: $0) })
    }

    static let maxPageLimit = 500
    static let maxWindowLimit = 2000

    static func page(view: MailboxView, after: ThreadCursor?, limit: Int, maxLimit: Int = maxPageLimit,
                     in db: Database) throws -> ThreadPage {
        guard let v = try resolve(view, in: db) else { return ThreadPage(items: []) }
        let n = min(max(limit, 1), maxLimit)
        let newestFirst = v.direction < 0
        let cmp = newestFirst ? "<" : ">"
        let order = newestFirst ? "DESC" : "ASC"
        var args: [any DatabaseValueConvertible] = [v.rid]
        var cursorSQL = ""
        if let after {
            cursorSQL = "AND (tl.sort_at, tl.tid) \(cmp) (?, ?)"
            args += [after.sortAt, after.tid]
        }
        args.append(n + 1)
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(listColumns), tl.sort_at, tl.unread
            FROM thread_labels AS tl JOIN threads AS t ON t.tid = tl.tid
            WHERE tl.label_rid = ? \(viewFilter(view)) \(cursorSQL)
            ORDER BY tl.sort_at \(order), tl.tid \(order)
            LIMIT ?
            """, arguments: StatementArguments(args.map { $0.databaseValue }))
        let decoder = JSONDecoder()
        let sortColumn = listColumnCount, unreadColumn = listColumnCount + 1
        let items = rows.prefix(n).map { listItem($0, sortAt: $0[sortColumn], unread: $0[unreadColumn], decoder: decoder) }
        var next: ThreadCursor?
        if rows.count > n {
            let last = rows[n - 1]
            next = ThreadCursor(sortAt: last[sortColumn], tid: last[0])
        }
        return ThreadPage(items: Array(items), nextCursor: next)
    }

    static func window(view: MailboxView, limit: Int, in db: Database) throws -> ThreadWindow {
        let p = try withCategories(page(view: view, after: nil, limit: limit, maxLimit: maxWindowLimit, in: db), in: db)
        var total = 0
        if let v = try resolve(view, in: db) {
            let extra = viewFilter(view)
            if extra.isEmpty {
                total = try Int.fetchOne(db, sql: "SELECT total_threads FROM labels WHERE label_rid = ?", arguments: [v.rid]) ?? 0
            } else {
                total = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM thread_labels AS tl JOIN threads AS t ON t.tid = tl.tid
                    WHERE tl.label_rid = ? \(extra)
                    """, arguments: [v.rid]) ?? 0
            }
        }
        return ThreadWindow(items: p.items, hasMore: p.nextCursor != nil, totalCount: total)
    }

    static func threadItem(tid: Int64, in db: Database) throws -> ThreadListItem? {
        guard let r = try Row.fetchOne(db, sql: "SELECT \(listColumns) FROM threads t WHERE t.tid = ?", arguments: [tid])
        else { return nil }
        return try withCategories(listItem(r, sortAt: r[14], unread: (r[8] as Int) > 0, decoder: JSONDecoder()), in: db)
    }

    static func attachmentItems(mids: [Int64], directory: URL, in db: Database) throws -> [Int64: [AttachmentItem]] {
        guard !mids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: mids.count).joined(separator: ", ")
        var out: [Int64: [AttachmentItem]] = [:]
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM attachments WHERE mid IN (\(marks))",
                                    arguments: StatementArguments(mids)).sorted { ($0["aid"] as Int64) < ($1["aid"] as Int64) }
        for r in rows {
            let mid: Int64 = r["mid"]
            out[mid, default: []].append(attachmentItem(r, directory: directory))
        }
        return out
    }

    static func localURL(_ relative: String?, directory: URL) -> URL? {
        guard let relative, !relative.isEmpty, !relative.hasPrefix("/") else { return nil }
        let base = directory.deletingLastPathComponent()
        let url = base.appendingPathComponent(relative).standardizedFileURL
        let allowed = directory.standardizedFileURL.path + "/"
        return url.path.hasPrefix(allowed) ? url : nil
    }

    static func attachmentItem(_ r: Row, directory: URL) -> AttachmentItem {
        AttachmentItem(id: r["aid"], messageRowID: MessageRowID(rawValue: r["mid"]), partID: r["part_id"],
                              filename: r["filename"], mimeType: r["mime_type"], size: r["size"],
                              contentID: r["content_id"], isInline: r["is_inline"],
                              localFileURL: localURL(r["local_path"], directory: directory))
    }

    static func messageItem(_ r: Row, attachments: [AttachmentItem]) -> MessageItem {
        func addrs(_ column: String) -> [EmailAddress] {
            WireAddress.decode(r[column]).map { EmailAddress(name: $0.n, email: $0.e) }
        }
        let from: EmailAddress? = (r["from_email"] as String?).map { EmailAddress(name: r["from_name"], email: $0) }
        let headerDate: Int64? = r["header_date"]
        let refs = (r["references_ids"] as String?)?.split(separator: " ").map(String.init) ?? []
        return MessageItem(
            id: MessageRowID(rawValue: r["mid"]), gmailMessageID: GmailMessageID(r["gmail_message_id"]),
            date: date(r["internal_date"]), headerDate: headerDate.map(date), from: from, to: addrs("to_json"),
            cc: addrs("cc_json"), bcc: addrs("bcc_json"), replyTo: addrs("reply_to_json"), subject: r["subject"],
            snippet: HTMLEntities.decode(r["snippet"]),
            labelIDs: (r["label_ids"] as String).split(separator: ",").map { GmailLabelID(String($0)) },
            isUnread: r["is_unread"], isStarred: r["is_starred"], isDraft: r["is_draft"], isFromMe: r["is_from_me"],
            inTrash: r["in_trash"], inSpam: r["in_spam"], rfc822MessageID: r["rfc822_message_id"],
            inReplyTo: r["in_reply_to"], references: refs, listUnsubscribe: r["list_unsubscribe"],
            listUnsubscribePost: r["list_unsubscribe_post"], hasCalendarInvite: r["has_calendar_invite"],
            bodyState: BodyState(rawValue: r["body_state"]) ?? .none, attachments: attachments)
    }

    static func detail(_ id: ThreadRowID, attachmentsDirectory: URL, in db: Database) throws -> ThreadDetail? {
        guard var item = try threadItem(tid: id.rawValue, in: db) else { return nil }
        item.sortAt = item.lastMessageAt
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM messages WHERE tid = ? ORDER BY internal_date ASC, mid ASC",
                                    arguments: [id.rawValue])
        let atts = try attachmentItems(mids: rows.map { $0["mid"] }, directory: attachmentsDirectory, in: db)
        let messages = rows.map { messageItem($0, attachments: atts[$0["mid"] as Int64] ?? []) }
        var labels: [LabelItem] = []
        for rid in item.userLabelIDs {
            if let r = try Row.fetchOne(db, sql: "SELECT * FROM labels WHERE label_rid = ?", arguments: [rid.rawValue]) {
                labels.append(labelItem(r))
            }
        }
        let drafts = try Row.fetchAll(db, sql: """
            SELECT * FROM drafts WHERE tid = ? AND state NOT IN ('sent', 'discarded') ORDER BY updated_at DESC, draft_uuid
            """, arguments: [id.rawValue]).map(draftItem)
        return ThreadDetail(thread: item, messages: messages, labels: labels, drafts: drafts,
                            snooze: try snoozeInfo(tid: id.rawValue, in: db), reminder: try reminderInfo(tid: id.rawValue, in: db),
                            hiddenMessageIDs: try hiddenReminderMessages(tid: id.rawValue, account: item.ref.accountID.rawValue,
                                                                         in: db))
    }

    static func bodyItem(_ id: MessageRowID, attachmentsDirectory: URL, in db: Database) throws -> MessageBody? {
        guard let r = try Row.fetchOne(db, sql: "SELECT * FROM message_bodies WHERE mid = ?", arguments: [id.rawValue])
        else { return nil }
        var inline: [String: AttachmentItem] = [:]
        for a in try Row.fetchAll(db, sql: "SELECT * FROM attachments WHERE mid = ? AND is_inline = 1 AND content_id IS NOT NULL",
                                  arguments: [id.rawValue]) {
            let item = attachmentItem(a, directory: attachmentsDirectory)
            if let cid = item.contentID { inline[cid] = item }
        }
        let warnings = (r["decode_warnings"] as String?)?.split(separator: "\n").map(String.init) ?? []
        let format = (r["text_format"] as String?).flatMap(BodyTextFormat.init(rawValue:)) ?? .fixed
        return MessageBody(messageRowID: id, html: r["html"], text: r["text"], hasRemoteContent: r["has_remote_content"],
                           inlineParts: inline, decodeWarnings: warnings, textFormat: format)
    }
}
