import Foundation
import GRDB
import OpenHumanCore

extension MailStore: SyncWriting {
    public func upsertLabels(_ labels: [LabelUpsert], account: AccountID, removeMissing: Bool) throws {
        try write { db in
            try requireAccount(account, in: db)
            let a = account.rawValue
            let now = nowMillis()
            var existing: [String: (rid: Int64, name: String, hidden: Bool, kind: String)] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT label_rid, key, name, is_hidden, kind FROM labels WHERE account_id = ?",
                                      arguments: [a]) {
                existing[r["key"]] = (r["label_rid"], r["name"], r["is_hidden"], r["kind"])
            }
            var touchedKeys = Set<String>(), namesNowKnown = Set<String>()
            for l in labels {
                let key = l.gmailLabelID.rawValue
                if key.hasPrefix("oh:") { continue }
                let kind = key.hasPrefix("CATEGORY_") ? "category" : (l.type == "system" ? "system" : "user")
                let display = l.name.split(separator: "/").last.map(String.init) ?? l.name
                let hidden = LabelVisibility.isHidden(name: l.name)
                try db.cached("""
                    INSERT INTO labels (account_id, key, kind, name, display_name, color_bg, color_text,
                                        label_list_visibility, message_list_visibility, is_hidden, position,
                                        server_threads_total, server_threads_unread, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (account_id, key) DO UPDATE SET
                        kind = excluded.kind, name = excluded.name, display_name = excluded.display_name,
                        color_bg = excluded.color_bg, color_text = excluded.color_text,
                        label_list_visibility = excluded.label_list_visibility,
                        message_list_visibility = excluded.message_list_visibility,
                        is_hidden = excluded.is_hidden, position = excluded.position,
                        server_threads_total = excluded.server_threads_total,
                        server_threads_unread = excluded.server_threads_unread, updated_at = excluded.updated_at
                    """).execute(arguments: [a, key, kind, l.name, display, l.colorBackground, l.colorText,
                                     l.labelListVisibility, l.messageListVisibility, hidden, Self.systemPosition(key),
                                     l.threadsTotal, l.threadsUnread, now])
                if let old = existing[key], old.name == l.name, old.hidden == hidden, old.kind == kind { continue }
                touchedKeys.insert(key)
                namesNowKnown.insert(l.name)
            }
            if removeMissing {
                let keep = Set(labels.map(\.gmailLabelID.rawValue))
                for (key, info) in existing where ["system", "category", "user"].contains(info.kind) && !keep.contains(key) {
                    try db.cached("DELETE FROM labels WHERE label_rid = ?").execute(arguments: [info.rid])
                    touchedKeys.insert(key)
                }
            }
            var tids = try Self.threadsCarrying(keys: touchedKeys, account: a, in: db)
            tids.formUnion(try LabelOverlay.labelRowsCreated(account: a, names: namesNowKnown, in: db))
            try ThreadAggregator.refresh(tids: tids, in: db)
        }
    }

    static func systemPosition(_ key: String) -> Int {
        let order = ["INBOX", "STARRED", "IMPORTANT", "UNREAD", "SENT", "DRAFT", "TRASH", "SPAM",
                     "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES",
                     "CATEGORY_FORUMS"]
        return order.firstIndex(of: key) ?? 0
    }

    static func threadsCarrying(keys: Set<String>, account: Int64, in db: Database) throws -> Set<Int64> {
        guard !keys.isEmpty else { return [] }
        var tids = Set<Int64>()
        let sorted = keys.sorted()
        for start in stride(from: 0, to: sorted.count, by: 50) {
            let chunk = sorted[start..<min(start + 50, sorted.count)]
            let clauses = chunk.map { _ in "instr(',' || label_ids || ',', ?) > 0" }.joined(separator: " OR ")
            tids.formUnion(try Int64.fetchAll(db, sql: """
                SELECT DISTINCT tid FROM messages WHERE account_id = ? AND (\(clauses))
                """, arguments: StatementArguments([account.databaseValue] + chunk.map { ("," + $0 + ",").databaseValue })))
        }
        return tids
    }

    public func upsertMessages(_ messages: [MessageUpsert], account: AccountID, generation: Int) throws -> UpsertResult {
        try upsert(messages, account: account, generation: generation)
    }

    func upsertSentCopy(_ message: MessageUpsert, account: AccountID) throws -> UpsertResult {
        try upsert([message], account: account, generation: nil)
    }

    private func upsert(_ messages: [MessageUpsert], account: AccountID, generation given: Int?) throws -> UpsertResult {
        UpsertRace.willUpsert(messages)
        return try write { db in
            try requireAccount(account, in: db)
            let a = account.rawValue
            let generation = try given ?? Int.fetchOne(db, sql: "SELECT generation FROM sync_state WHERE account_id = ?",
                                                        arguments: [a]) ?? 1
            let me = try ThreadAggregator.myAddresses(account: a, in: db)
            let known = Set(try String.fetchAll(db.cached("SELECT key FROM labels WHERE account_id = ?"), arguments: [a]))
            var inserted = 0, updated = 0, stale = 0, tombstoned = 0
            var tids = Set<Int64>(), mids = Set<Int64>()
            var unknown = Set<GmailLabelID>()
            let now = nowMillis()
            let guarding = try EchoGuard.anyAwaiting(in: db)

            for m in messages {
                let incoming = Int64(clamping: m.historyID.rawValue)
                if let tomb = try Int64.fetchOne(db.cached("""
                    SELECT history_id FROM deleted_messages WHERE account_id = ? AND gmail_message_id = ?
                    """), arguments: [a, m.gmailMessageID.rawValue]), tomb >= incoming {
                    tombstoned += 1
                    continue
                }
                let existing = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE account_id = ? AND gmail_message_id = ?",
                                                arguments: [a, m.gmailMessageID.rawValue])
                let tid: Int64
                if let existing { tid = existing["tid"] } else {
                    tid = try threadRow(account: account, thread: m.gmailThreadID, now: now, in: db)
                }
                let isStale = existing.map { incoming < ($0["history_id"] as Int64) } ?? false
                let bodyState: Int = existing?["body_state"] ?? 0
                let hadHeaders = bodyState >= BodyState.metadataOnly.rawValue

                var cols: [(String, DatabaseValue)] = []
                if !isStale {
                    cols += [("history_id", incoming.databaseValue),
                             ("internal_date", Self.storeMillis(m.internalDate).databaseValue),
                             ("snippet", m.snippet.databaseValue), ("size_estimate", m.sizeEstimate.databaseValue),
                             ("server_label_ids", Labels.join(Set(m.labelIDs.map(\.rawValue))).databaseValue)]
                    for id in m.labelIDs where !known.contains(id.rawValue) { unknown.insert(id) }
                }
                let oldGeneration: Int = existing?["sync_generation"] ?? 0
                if existing == nil || oldGeneration < generation { cols.append(("sync_generation", generation.databaseValue)) }

                var headersWritten = false
                if let h = m.headers {
                    let values = Self.headerColumns(h, me: me)
                    if let existing, isStale {
                        for (col, value) in values where Self.isEmpty(existing[col]) && !Self.isEmpty(value) {
                            cols.append((col, value))
                            headersWritten = true
                        }
                    } else {
                        cols += values
                        headersWritten = true
                    }
                    if !hadHeaders && m.body == nil { cols.append(("body_state", BodyState.metadataOnly.rawValue.databaseValue)) }
                }
                if let atts = m.attachments { cols.append(("has_attachments", AttachmentRows.hasAttachments(atts).databaseValue)) }
                if let body = m.body {
                    cols.append(("has_calendar_invite", body.hasCalendarInvite.databaseValue))
                    cols.append(("body_state", BodyState.stored.rawValue.databaseValue))
                }

                let mid: Int64
                if let existing {
                    mid = existing["mid"]
                    if isStale { stale += 1 } else { updated += 1 }
                    let changes = cols.filter { (existing[$0.0] as DatabaseValue) != $0.1 }
                    if !changes.isEmpty {
                        let sets = changes.map { "\($0.0) = ?" }.joined(separator: ", ")
                        var args = StatementArguments(changes.map(\.1))
                        args += [now, mid]
                        try db.execute(sql: "UPDATE messages SET \(sets), updated_at = ? WHERE mid = ?", arguments: args)
                    }
                    if guarding, !isStale {
                        try EchoGuard.snapshot(mid: mid, account: a, labels: Set(m.labelIDs.map(\.rawValue)), in: db)
                    }
                } else {
                    inserted += 1
                    let all: [(String, DatabaseValue)] = [
                        ("account_id", a.databaseValue), ("gmail_message_id", m.gmailMessageID.rawValue.databaseValue),
                        ("tid", tid.databaseValue), ("updated_at", now.databaseValue),
                    ] + cols
                    let names = all.map(\.0).joined(separator: ", ")
                    let marks = Array(repeating: "?", count: all.count).joined(separator: ", ")
                    try db.execute(sql: "INSERT INTO messages (\(names)) VALUES (\(marks))",
                                   arguments: StatementArguments(all.map(\.1)))
                    mid = db.lastInsertedRowID
                }
                if let body = m.body { try Self.writeBody(mid: mid, body, now: now, in: db) }
                if let atts = m.attachments { try AttachmentRows.replace(mid: mid, account: a, atts, in: db) }

                if let h = m.headers, !hadHeaders, headersWritten {
                    try ContactCounter.count(
                        account: a, from: h.from.map { ($0.name, $0.email) },
                        recipients: (h.to + h.cc + h.bcc).map { ($0.name, $0.email) },
                        date: Self.storeMillis(m.internalDate),
                        isFromMe: h.from.map { me.contains($0.email.lowercased()) } ?? false,
                        labels: Set(m.labelIDs.map(\.rawValue)), me: me, in: db)
                }

                let snippetChanged = !isStale && (existing?["snippet"] as String?) != m.snippet
                if existing == nil || headersWritten || m.body != nil || m.attachments != nil || snippetChanged {
                    var update = SearchDocuments.Update()
                    if let h = m.headers, headersWritten {
                        if isStale {
                            update = try Self.searchHeadersFromRow(mid: mid, in: db)
                        } else {
                            update.subject = h.subject
                            update.participants = SearchDocuments.participants(
                                from: h.from.map { .init(name: $0.name, email: $0.email) },
                                to: h.to.map { .init(name: $0.name, email: $0.email) },
                                cc: h.cc.map { .init(name: $0.name, email: $0.email) })
                        }
                    }
                    update.bodyText = m.body?.searchText
                    update.snippet = isStale ? nil : m.snippet
                    update.attachmentNames = m.attachments?.map(\.filename)
                    update.hasStoredBody = m.body != nil || bodyState == BodyState.stored.rawValue
                    try SearchDocuments.write(mid: mid, update, in: db)
                }
                mids.insert(mid)
                tids.insert(tid)
            }
            try LabelOverlay.recompute(mids: mids, in: db)
            try ThreadAggregator.refresh(tids: tids, in: db)
            return UpsertResult(inserted: inserted, updated: updated, skippedStale: stale,
                                skippedTombstoned: tombstoned, touchedThreads: Set(tids.map { ThreadRowID(rawValue: $0) }),
                                unknownLabelIDs: unknown)
        }
    }

    public func storeBodies(_ bodies: [(GmailMessageID, MessageBodyUpsert, [AttachmentUpsert])],
                            account: AccountID) throws {
        try write { db in
            let now = nowMillis()
            var tids = Set<Int64>()
            for (id, body, attachments) in bodies {
                guard let row = try Row.fetchOne(db.cached("""
                    SELECT mid, tid FROM messages WHERE account_id = ? AND gmail_message_id = ?
                    """), arguments: [account.rawValue, id.rawValue]) else { continue }
                let mid: Int64 = row["mid"]
                try Self.writeBody(mid: mid, body, now: now, in: db)
                try AttachmentRows.replace(mid: mid, account: account.rawValue, attachments, in: db)
                try db.cached("""
                    UPDATE messages SET body_state = 2, has_calendar_invite = ?, has_attachments = ?, updated_at = ?
                    WHERE mid = ?
                    """).execute(arguments: [body.hasCalendarInvite, AttachmentRows.hasAttachments(attachments), now, mid])
                try SearchDocuments.write(mid: mid, .init(bodyText: body.searchText,
                                                          attachmentNames: attachments.map(\.filename)), in: db)
                tids.insert(row["tid"])
            }
            try ThreadAggregator.refresh(tids: tids, in: db)
        }
    }

    public func markBodyFailed(_ id: GmailMessageID, account: AccountID, reason: String) throws {
        try write { db in
            try db.cached("""
                UPDATE messages SET body_state = 3, updated_at = ?
                WHERE account_id = ? AND gmail_message_id = ? AND body_state <> 2
                """).execute(arguments: [nowMillis(), account.rawValue, id.rawValue])
        }
        Self.syncWritesLog.notice("body marked failed for one message of account \(account.rawValue): \(reason)")
    }

    public func messagesNeedingBodies(account: AccountID, newerThan: Date, limit: Int) throws -> [GmailMessageID] {
        try read { db in
            try String.fetchAll(db.cached("""
                SELECT gmail_message_id FROM messages
                WHERE account_id = ? AND body_state < 2 AND internal_date >= ?
                ORDER BY internal_date DESC LIMIT ?
                """), arguments: [account.rawValue, Self.storeMillis(newerThan), max(limit, 0)])
                .map { GmailMessageID($0) }
        }
    }

    public func messagesNeedingInviteCheck(account: AccountID, limit: Int) throws -> [GmailMessageID] {
        guard limit > 0 else { return [] }
        return try read { db in
            try String.fetchAll(db.cached("""
                SELECT gmail_message_id FROM messages m
                WHERE m.account_id = ? AND m.body_state < 2 AND m.is_draft = 0 AND m.in_trash = 0 AND m.in_spam = 0
                  AND \(Self.inviteCheckSQL)
                ORDER BY (instr(',' || m.label_ids || ',', ',INBOX,') > 0) DESC, m.internal_date DESC LIMIT ?
                """), arguments: [account.rawValue, limit])
                .map { GmailMessageID($0) }
        }
    }

    static let inviteCheckSQL: String = {
        func literal(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        let subject = "ltrim(lower(COALESCE(m.subject, '')), ' ')"
        var parts = ["lower(COALESCE(m.from_email, '')) IN ("
            + EventMailSignals.calendarSenders.sorted().map(literal).joined(separator: ", ") + ")"]
        for marker in EventMailSignals.replyMarkers {
            for prefix in EventMailSignals.invitationSubjectPrefixes {
                parts.append("substr(\(subject), 1, \((marker + prefix).count)) = " + literal(marker + prefix))
            }
        }
        return "(" + parts.joined(separator: " OR ") + ")"
    }()

    public func bodyCounts(account: AccountID) throws -> BodyCounts {
        try read { db in
            var counts = BodyCounts()
            for row in try Row.fetchAll(db.cached("""
                SELECT body_state, COUNT(*) AS n FROM messages WHERE account_id = ? GROUP BY body_state
                """), arguments: [account.rawValue]) {
                let n: Int = row["n"]
                switch row["body_state"] as Int {
                case 2: counts.stored += n
                case 3: counts.failed += n
                default: counts.pending += n
                }
            }
            return counts
        }
    }

    public func knownMessageIDs(account: AccountID, among: [GmailMessageID]) throws -> Set<GmailMessageID> {
        try read { db in
            var result = Set<GmailMessageID>()
            for chunk in stride(from: 0, to: among.count, by: 500).map({ Array(among[$0..<min($0 + 500, among.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let found = try String.fetchAll(db, sql: """
                    SELECT gmail_message_id FROM messages WHERE account_id = ? AND gmail_message_id IN (\(marks))
                    """, arguments: StatementArguments([account.rawValue] + chunk.map(\.rawValue)))
                result.formUnion(found.map { GmailMessageID($0) })
            }
            return result
        }
    }

    public func threadsNeedingFetch(account: AccountID, stubs: [(GmailThreadID, HistoryID)]) throws -> [GmailThreadID] {
        try read { db in
            try stubs.filter { stub in
                let have = try Int64.fetchOne(db.cached("""
                    SELECT history_id FROM threads WHERE account_id = ? AND gmail_thread_id = ?
                    """), arguments: [account.rawValue, stub.0.rawValue])
                return have.map { $0 < Int64(clamping: stub.1.rawValue) } ?? true
            }.map(\.0)
        }
    }

    public func inboxThreads(account: AccountID, labelled label: GmailLabelID) throws -> [ThreadRef] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.tid, t.gmail_thread_id FROM labels l
                JOIN thread_labels tl ON tl.label_rid = l.label_rid
                JOIN threads t ON t.tid = tl.tid
                WHERE l.account_id = ? AND l.key = ? AND t.in_inbox = 1
                ORDER BY t.tid
                """, arguments: [account.rawValue, label.rawValue]).map {
                ThreadRef(accountID: account, rowID: ThreadRowID(rawValue: $0["tid"]),
                          gmailThreadID: GmailThreadID($0["gmail_thread_id"] as String))
            }
        }
    }

    // Absolute paths and `..` are refused so a row can never point outside the store
    public func setAttachmentDownloaded(aid: Int64, relativePath: String) throws {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !parts.contains(".."), !parts.contains("") else {
            throw StoreError.conflict("attachment path must be relative to the store directory")
        }
        try write { db in
            try db.execute(sql: "UPDATE attachments SET local_path = ?, downloaded_at = ? WHERE aid = ?",
                           arguments: [relativePath, nowMillis(), aid])
            if db.changesCount == 0 { throw StoreError.notFound("attachment \(aid)") }
        }
    }

    public func updateSendAs(account: AccountID, identities: [SendAsIdentity]) throws {
        try write { db in
            try requireAccount(account, in: db)
            let a = account.rawValue
            let before = try ThreadAggregator.myAddresses(account: a, in: db)
            let data = try StoreJSON.encoder.encode(identities)
            try db.execute(sql: "UPDATE accounts SET send_as_json = ?, updated_at = ? WHERE account_id = ?",
                           arguments: [String(decoding: data, as: UTF8.self), nowMillis(), a])
            let after = try ThreadAggregator.myAddresses(account: a, in: db)
            guard before != after else { return }
            let mine = after.sorted()
            let marks = Array(repeating: "?", count: mine.count).joined(separator: ", ")
            let expr = "(from_email IS NOT NULL AND lower(from_email) IN (\(marks)))"
            let rows = try Row.fetchAll(db, sql: """
                SELECT mid, tid FROM messages WHERE account_id = ? AND is_from_me <> \(expr)
                """, arguments: StatementArguments([a.databaseValue] + mine.map(\.databaseValue)))
            for row in rows {
                try db.execute(sql: "UPDATE messages SET is_from_me = NOT is_from_me WHERE mid = ?",
                               arguments: [row["mid"] as Int64])
            }
            try ThreadAggregator.refresh(tids: Set(rows.map { $0["tid"] as Int64 }), in: db)
        }
    }

    static let syncWritesLog = Log(.store)

    func requireAccount(_ id: AccountID, in db: Database) throws {
        if try Int.fetchOne(db.cached("SELECT 1 FROM accounts WHERE account_id = ?"), arguments: [id.rawValue]) == nil {
            throw StoreError.notFound("account \(id.rawValue)")
        }
    }

    func threadRow(account: AccountID, thread: GmailThreadID, now: Int64, in db: Database) throws -> Int64 {
        if let tid = try Int64.fetchOne(db, sql: "SELECT tid FROM threads WHERE account_id = ? AND gmail_thread_id = ?",
                                        arguments: [account.rawValue, thread.rawValue]) { return tid }
        try db.execute(sql: "INSERT INTO threads (account_id, gmail_thread_id, updated_at) VALUES (?, ?, ?)",
                       arguments: [account.rawValue, thread.rawValue, now])
        return db.lastInsertedRowID
    }

    static func writeBody(mid: Int64, _ body: MessageBodyUpsert, now: Int64, in db: Database) throws {
        let html = body.html
        let remote = html.map { $0.contains("http://") || $0.contains("https://") } ?? false
        try db.cached("""
            INSERT INTO message_bodies (mid, html, text, html_byte_count, has_remote_content, decode_warnings, fetched_at,
                                        text_format)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (mid) DO UPDATE SET html = excluded.html, text = excluded.text,
                html_byte_count = excluded.html_byte_count, has_remote_content = excluded.has_remote_content,
                decode_warnings = excluded.decode_warnings, fetched_at = excluded.fetched_at,
                text_format = excluded.text_format
            """).execute(arguments: [mid, html, body.text, html?.utf8.count ?? 0, remote,
                             body.decodeWarnings.isEmpty ? nil : body.decodeWarnings.joined(separator: "\n"), now,
                             body.textFormat.rawValue])
    }

    static func headerColumns(_ h: MessageHeaderFields, me: Set<String>) -> [(String, DatabaseValue)] {
        let fromEmail = h.from?.email
        let fromName = h.from?.name
        return [
            ("subject", h.subject.databaseValue), ("from_name", fromName.databaseValue),
            ("from_email", fromEmail.databaseValue),
            ("to_json", json(h.to).databaseValue), ("cc_json", json(h.cc).databaseValue),
            ("bcc_json", json(h.bcc).databaseValue), ("reply_to_json", json(h.replyTo).databaseValue),
            ("header_date", h.date.map { storeMillis($0) }.databaseValue),
            ("rfc822_message_id", h.messageID.map(AttachmentRows.stripBrackets).databaseValue),
            ("in_reply_to", h.inReplyTo.map(AttachmentRows.stripBrackets).databaseValue),
            ("references_ids", h.references.map(AttachmentRows.stripBrackets).joined(separator: " ").databaseValue),
            ("list_id", h.listID.databaseValue), ("list_unsubscribe", h.listUnsubscribe.databaseValue),
            ("list_unsubscribe_post", h.listUnsubscribePost.databaseValue),
            ("is_from_me", (fromEmail.map { me.contains($0.lowercased()) } ?? false).databaseValue),
        ]
    }

    static func isEmpty(_ value: DatabaseValue) -> Bool {
        switch value.storage {
        case .null: return true
        case let .string(s): return s.isEmpty || s == "[]"
        case let .int64(i): return i == 0
        default: return false
        }
    }

    private static func searchHeadersFromRow(mid: Int64, in db: Database) throws -> SearchDocuments.Update {
        guard let r = try Row.fetchOne(db, sql: "SELECT subject, from_name, from_email, to_json, cc_json FROM messages WHERE mid = ?",
                                       arguments: [mid]) else { return .init() }
        let from: String? = r["from_email"]
        return SearchDocuments.Update(
            subject: r["subject"],
            participants: SearchDocuments.participants(
                from: from.map { .init(name: r["from_name"], email: $0) },
                to: WireAddress.decode(r["to_json"]).map { .init(name: $0.n, email: $0.e) },
                cc: WireAddress.decode(r["cc_json"]).map { .init(name: $0.n, email: $0.e) }))
    }

    private static func json(_ list: [EmailAddress]) -> String {
        WireAddress.encode(list.map { WireAddress(n: $0.name, e: $0.email) })
    }
}
