import Foundation
import GRDB
import OpenHumanCore

enum ThreadAggregator {
    private static let log = Log(.store)

    struct Message {
        var mid: Int64
        var gmailID: String
        var internalDate: Int64
        var subject: String
        var snippet: String
        var fromName: String?
        var fromEmail: String?
        var toJSON: String
        var ccJSON: String
        var labels: Set<String>
        var isDraft: Bool
        var inTrash: Bool
        var inSpam: Bool
        var isUnread: Bool
        var isFromMe: Bool
        var historyID: Int64
        var hasAttachments: Bool
        var hasCalendarInvite: Bool
        var listID: String?
        var visible: Bool { !inTrash && !inSpam && !isDraft }
        var isOwn: Bool { isFromMe || labels.contains("SENT") }
        // The account's own message never counts as unread, even if its copy carries UNREAD (alias or group copy)
        var countsUnread: Bool { isUnread && !isOwn }
    }

    struct Draft {
        var uuid: String
        var state: DraftState
        var sendAt: Int64?
        var lastError: String?
        var isDirty: Bool
        var sendAtHeader: String?
        var gmailMessageID: String?
        var subject: String
        var isActive: Bool { state != .sent && state != .discarded }
    }

    static func refresh(tids: Set<Int64>, in db: Database) throws {
        var contexts: [Int64: AggregationContext] = [:]
        for tid in tids.sorted() {
            guard let existing = try Row.fetchOne(db.cached("SELECT * FROM threads WHERE tid = ?"), arguments: [tid])
            else { continue }
            let account: Int64 = existing["account_id"]
            let context: AggregationContext
            if let cached = contexts[account] {
                context = cached
            } else {
                context = try AggregationContext.load(account: account, in: db)
                contexts[account] = context
            }
            try refresh(tid: tid, existing: existing, context: context, in: db)
        }
    }

    static func myAddresses(account: Int64, in db: Database) throws -> Set<String> {
        guard let row = try Row.fetchOne(db, sql: "SELECT email, send_as_json FROM accounts WHERE account_id = ?",
                                         arguments: [account]) else { return [] }
        var set: Set<String> = [(row["email"] as String).lowercased()]
        if let data = (row["send_as_json"] as String).data(using: .utf8),
           let ids = try? JSONDecoder().decode([WireSendAs].self, from: data) {
            for id in ids { set.insert(id.email.lowercased()) }
        }
        return set
    }

    private static func refresh(tid: Int64, existing: Row, context: AggregationContext, in db: Database) throws {
        let messages = try loadMessages(tid: tid, in: db)
        let drafts = try loadDrafts(tid: tid, in: db)
        let activeDrafts = drafts.filter(\.isActive)
        if messages.isEmpty && activeDrafts.isEmpty {
            try db.cached("DELETE FROM thread_labels WHERE tid = ?").execute(arguments: [tid])
            try db.cached("DELETE FROM threads WHERE tid = ?").execute(arguments: [tid])
            return
        }
        let gmailThreadID: String = existing["gmail_thread_id"]
        let now = nowMillis()

        let reminderRule = context.superhumanReminders
        let reminderCandidates = reminderRule.isActive ? messages.map { SuperhumanReminderRule.Candidate($0) } : []
        let hiddenReminders = reminderRule.hiddenMids(reminderCandidates)
        let shown = hiddenReminders.isEmpty ? messages : messages.filter { !hiddenReminders.contains($0.mid) }
        let allHidden = !hiddenReminders.isEmpty && shown.isEmpty && activeDrafts.isEmpty
        let basis = allHidden ? messages : shown

        let visible = basis.filter(\.visible)
        let nonDraft = basis.filter { !$0.isDraft }
        let draftMessages = basis.filter(\.isDraft)
        let scope = !visible.isEmpty ? visible : (!nonDraft.isEmpty ? nonDraft : draftMessages)
        let notTrashed = messages.filter { !$0.inTrash && !$0.inSpam }
        let inInbox = !allHidden && notTrashed.contains { !$0.isDraft && $0.labels.contains("INBOX") }
        let lastMessageAt = scope.map(\.internalDate).max() ?? 0
        var inboxLastAt = lastMessageAt
        if inInbox, let muted = context.keyByName[OHGmailLabels.muted] {
            inboxLastAt = scope.lazy.filter { !$0.labels.contains(muted) || $0.labels.contains("INBOX") }
                .map(\.internalDate).max() ?? lastMessageAt
        }
        let visibleUnread = visible.contains(where: \.countsUnread)

        let previousSnooze = try loadSnooze(tid: tid, in: db)
        let pending = !context.hasPendingAddNames ? [:]
            : try LabelOverlay.pendingNames(mids: messages.map(\.mid), account: context.account,
                                            knownNames: context.keyByName, in: db)
        let snoozeInput = messages.map {
            ScheduleDerivation.MessageLabels(visible: $0.visible,
                                             names: context.names(of: $0.labels) + (pending[$0.mid] ?? []))
        }
        var snooze = previousSnooze
        var snoozeDerived = false
        do {
            try DerivationFaults.check(.snooze, thread: gmailThreadID)
            snooze = try ScheduleDerivation.deriveSnoozes(snoozeInput)
            snoozeDerived = true
        } catch {
            log.error("snooze derivation failed for thread \(tid) (\(storeLogCode(error))); "
                      + "its snooze cache is left unchanged")
        }

        var draftUpdates: [(uuid: String, value: ScheduleDerivation.DraftSchedule)] = []
        var scheduledSendAt: Int64? = existing["scheduled_send_at"]
        do {
            try DerivationFaults.check(.sendLater, thread: gmailThreadID)
            var earliest: Int64?
            for d in activeDrafts {
                let names = d.gmailMessageID.flatMap { id in messages.first { $0.gmailID == id } }
                    .map { context.names(of: $0.labels) } ?? []
                let current = ScheduleDerivation.DraftSchedule(state: d.state, sendAt: d.sendAt, lastError: d.lastError)
                let derived = try ScheduleDerivation.deriveScheduledSend(.init(
                    isDirty: d.isDirty, current: current, header: d.sendAtHeader, labelNames: names))
                if derived != current { draftUpdates.append((d.uuid, derived)) }
                if derived.state == .scheduled, let at = derived.sendAt { earliest = min(earliest ?? at, at) }
            }
            scheduledSendAt = earliest
        } catch {
            draftUpdates = []
            log.error("send-later derivation failed for thread \(tid) (\(storeLogCode(error))); its drafts are left unchanged")
        }

        let reminderAt = try Int64.fetchOne(db.cached("""
            SELECT due_at FROM reminders WHERE tid = ? AND state = 'active' ORDER BY due_at LIMIT 1
            """), arguments: [tid])

        let placement = inInbox
            ? ImportanceEvaluator.place(try placementFacts(visible: visible, tid: tid, gmailThreadID: gmailThreadID,
                                                           context: context, in: db),
                                        context: context)
            : Placement()
        let splitRid = placement.splitRid

        var boost: Int64? = existing["sort_boost_at"]
        let wasInInbox: Bool = existing["in_inbox"]
        let previousLast: Int64 = existing["last_message_at"]
        if snoozeDerived, previousSnooze != nil, snooze == nil, inInbox, !wasInInbox, lastMessageAt <= previousLast {
            boost = boost ?? now
        }
        if inInbox, let back = reminderRule.returnAt(reminderCandidates, hidden: hiddenReminders, gmailThreadID: gmailThreadID),
           back > lastMessageAt {
            boost = max(boost ?? 0, back)
        }
        if let b = boost, !inInbox || lastMessageAt > b { boost = nil }

        var attachmentCounts: [Int64: Int] = [:]
        if !messages.isEmpty {
            for r in try Row.fetchAll(db.cached("""
                SELECT a.mid, count(*) AS n FROM attachments a JOIN messages m ON m.mid = a.mid
                WHERE m.tid = ? AND a.is_inline = 0 GROUP BY a.mid
                """), arguments: [tid]) { attachmentCounts[r["mid"]] = r["n"] }
        }

        var userRids = Set<Int64>()
        for m in scope {
            for key in m.labels {
                if let info = context.byKey[key], info.kind == "user", !info.hidden { userRids.insert(info.rid) }
            }
        }
        let backed = Set(drafts.compactMap(\.gmailMessageID))
        let draftCount = activeDrafts.count + draftMessages.filter { !backed.contains($0.gmailID) }.count
        let (display, json) = Participants.render(scope.map {
            Participants.Sender(name: $0.fromName, email: $0.fromEmail, isFromMe: $0.isFromMe, isUnread: $0.countsUnread,
                                toJSON: $0.toJSON, ccJSON: $0.ccJSON)
        }, me: context.me)
        let subject = (nonDraft.first ?? basis.first)?.subject ?? activeDrafts.first?.subject ?? ""
        let snoozedUntil = snooze?.wakeAt

        let new: [(String, (any DatabaseValueConvertible)?)] = [
            ("subject", subject),
            ("snippet", HTMLEntities.decode(scope.last?.snippet ?? "")),
            ("participants_display", display),
            ("participants_json", json),
            ("message_count", scope.count),
            ("unread_count", scope.filter(\.countsUnread).count),
            ("draft_count", draftCount),
            ("attachment_count", scope.reduce(0) { $0 + (attachmentCounts[$1.mid] ?? 0) }),
            ("is_starred", scope.contains { $0.labels.contains("STARRED") }),
            ("is_important", scope.contains { $0.labels.contains("IMPORTANT") }),
            ("in_inbox", inInbox),
            ("is_trashed", !messages.isEmpty && messages.allSatisfy(\.inTrash)),
            ("is_spam", !messages.isEmpty && messages.allSatisfy(\.inSpam)),
            ("user_label_rids", userRids.sorted().map(String.init).joined(separator: ",")),
            ("last_message_at", lastMessageAt),
            ("history_id", messages.map(\.historyID).max() ?? 0),
            ("sort_boost_at", boost),
            ("split_rid", splitRid),
            ("importance", placement.importance.rawValue),
            ("importance_reason_rid", placement.reasonRid),
            ("split_chip_rids", placement.chipText),
            ("snoozed_until", snoozedUntil),
            ("reminder_at", reminderAt),
            ("scheduled_send_at", scheduledSendAt),
        ]
        var changed: [(String, DatabaseValue)] = []
        for (col, value) in new {
            let v = value?.databaseValue ?? .null
            if (existing[col] as DatabaseValue) != v { changed.append((col, v)) }
        }
        if !changed.isEmpty {
            let sets = changed.map { "\($0.0) = ?" }.joined(separator: ", ")
            var args = StatementArguments(changed.map(\.1))
            args += [now, tid]
            try db.execute(sql: "UPDATE threads SET \(sets), updated_at = ? WHERE tid = ?", arguments: args)
        }

        if snoozeDerived && snooze != previousSnooze {
            try writeSnooze(snooze, tid: tid, account: context.account, gmailThreadID: gmailThreadID, in: db)
        }
        for update in draftUpdates {
            try db.execute(sql: "UPDATE drafts SET state = ?, send_at = ?, last_error = ?, updated_at = ? WHERE draft_uuid = ?",
                           arguments: [update.value.state.rawValue, update.value.sendAt, update.value.lastError, now,
                                       update.uuid])
        }

        let sortBase = max(lastMessageAt, boost ?? 0)
        let inboxSortAt = max(inboxLastAt, boost ?? 0)
        var desired: [Int64: (sortAt: Int64, unread: Bool)] = [:]
        func put(_ key: String, _ sortAt: Int64, _ unread: Bool) {
            if let rid = context.ridByKey[key] { desired[rid] = (sortAt, unread) }
        }
        for key in Set((allHidden ? [] : shown).flatMap(\.labels)) {
            let members: [Message]
            let sortAt: Int64
            switch key {
            case "SENT":
                members = shown.filter { $0.labels.contains("SENT") && !$0.inTrash && !$0.inSpam }
                sortAt = members.map(\.internalDate).max() ?? 0
            case "DRAFT", "TRASH", "SPAM":
                members = shown.filter { $0.labels.contains(key) }
                sortAt = members.map(\.internalDate).max() ?? 0
            case "UNREAD":
                members = messages.filter { $0.labels.contains(key) && !$0.inTrash && !$0.inSpam && $0.countsUnread }
                sortAt = sortBase
            default:
                members = shown.filter { $0.labels.contains(key) && !$0.inTrash && !$0.inSpam && !(key == "INBOX" && $0.isDraft) }
                sortAt = key == "INBOX" ? inboxSortAt : sortBase
            }
            if !members.isEmpty { put(key, sortAt, members.contains(where: \.countsUnread)) }
        }
        if inInbox, let inboxRid = context.ridByKey["INBOX"], desired[inboxRid] == nil {
            desired[inboxRid] = (inboxSortAt, false)
        }
        if !allHidden {
            if !visible.isEmpty { put("oh:allmail", lastMessageAt, visibleUnread) }
            if let snooze { put("oh:snoozed", snooze.wakeAt ?? 0, visibleUnread) }
            if let scheduledSendAt { put("oh:scheduled", scheduledSendAt, visibleUnread) }
            if let reminderAt { put("oh:reminders", reminderAt, visibleUnread) }
            if let waitingSince = WaitingRule.waitingSince(tid: tid, visible: visible, context: context) {
                put("oh:waiting", waitingSince, false)
            }
        }
        if inInbox {
            for rid in context.inboxSplitRids(placement) { desired[rid] = (inboxSortAt, visibleUnread) }
        }

        var present = Set<Int64>()
        for r in try Row.fetchAll(db, sql: "SELECT label_rid, sort_at, unread FROM thread_labels WHERE tid = ?",
                                  arguments: [tid]) {
            let rid: Int64 = r["label_rid"]
            let sortAt: Int64 = r["sort_at"]
            let unread: Bool = r["unread"]
            if let want = desired[rid], want.sortAt == sortAt, !present.contains(rid) {
                if want.unread != unread {
                    try db.execute(sql: "UPDATE thread_labels SET unread = ? WHERE label_rid = ? AND sort_at = ? AND tid = ?",
                                   arguments: [want.unread, rid, sortAt, tid])
                }
                present.insert(rid)
            } else {
                try db.execute(sql: "DELETE FROM thread_labels WHERE label_rid = ? AND sort_at = ? AND tid = ?",
                               arguments: [rid, sortAt, tid])
            }
        }
        for (rid, want) in desired where !present.contains(rid) {
            try db.execute(sql: "INSERT INTO thread_labels (label_rid, sort_at, tid, unread) VALUES (?, ?, ?, ?)",
                           arguments: [rid, want.sortAt, tid, want.unread])
        }
    }

    static func placementFacts(visible: [Message], tid: Int64, gmailThreadID: String?, context: AggregationContext,
                               in db: Database) throws -> SplitFacts {
        var messages = visible.map { splitFacts($0, context: context) }
        if context.readsText && !messages.isEmpty {
            let texts = try ImportanceText.load(tid: tid, in: db)
            for i in messages.indices { messages[i].text = texts[messages[i].mid] }
        }
        return SplitFacts(messages: messages, gmailThreadID: gmailThreadID)
    }

    static func loadMessages(tid: Int64, in db: Database) throws -> [Message] {
        try Row.fetchAll(db.cached("""
            SELECT mid, gmail_message_id, internal_date, subject, snippet, from_name, from_email, to_json, cc_json,
                   label_ids, is_draft, in_trash, in_spam, is_unread, is_from_me, history_id, has_attachments,
                   has_calendar_invite, list_id
            FROM messages WHERE tid = ? ORDER BY internal_date ASC, mid ASC
            """), arguments: [tid]).map { r in
            Message(mid: r["mid"], gmailID: r["gmail_message_id"], internalDate: r["internal_date"], subject: r["subject"],
                    snippet: r["snippet"], fromName: r["from_name"], fromEmail: r["from_email"], toJSON: r["to_json"],
                    ccJSON: r["cc_json"], labels: Labels.split(r["label_ids"]), isDraft: r["is_draft"],
                    inTrash: r["in_trash"], inSpam: r["in_spam"], isUnread: r["is_unread"], isFromMe: r["is_from_me"],
                    historyID: r["history_id"], hasAttachments: r["has_attachments"],
                    hasCalendarInvite: r["has_calendar_invite"], listID: r["list_id"])
        }
    }

    private static func loadDrafts(tid: Int64, in db: Database) throws -> [Draft] {
        try Row.fetchAll(db.cached("""
            SELECT draft_uuid, state, send_at, last_error, local_version, synced_version, extra_headers_json,
                   gmail_message_id, subject
            FROM drafts WHERE tid = ? ORDER BY created_at, draft_uuid
            """), arguments: [tid]).map { r in
            let state = DraftState(rawValue: r["state"]) ?? .editing
            let local: Int = r["local_version"], synced: Int = r["synced_version"]
            let headers: String = r["extra_headers_json"]
            return Draft(uuid: r["draft_uuid"], state: state, sendAt: r["send_at"], lastError: r["last_error"],
                         isDirty: local > synced,
                         sendAtHeader: state == .sent || state == .discarded ? nil
                            : DraftRowCodec.header(OHGmailLabels.sendAtHeader, in: DraftRowCodec.decodeHeaders(headers)),
                         gmailMessageID: r["gmail_message_id"], subject: r["subject"])
        }
    }

    private static func loadSnooze(tid: Int64, in db: Database) throws -> ScheduleDerivation.Snooze? {
        try Row.fetchOne(db, sql: "SELECT wake_at, label_name, stamp_label_count, status FROM snoozes WHERE tid = ?",
                         arguments: [tid]).map { r in
            ScheduleDerivation.Snooze(status: ScheduleDerivation.Snooze.Status(rawValue: r["status"]) ?? .malformed,
                                      wakeAt: r["wake_at"], labelName: r["label_name"],
                                      stampLabelCount: r["stamp_label_count"])
        }
    }

    private static func writeSnooze(_ snooze: ScheduleDerivation.Snooze?, tid: Int64, account: Int64,
                                    gmailThreadID: String, in db: Database) throws {
        guard let snooze else {
            try db.cached("DELETE FROM snoozes WHERE tid = ?").execute(arguments: [tid])
            return
        }
        try db.cached("""
            INSERT INTO snoozes (tid, account_id, gmail_thread_id, wake_at, label_name, stamp_label_count, status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (tid) DO UPDATE SET wake_at = excluded.wake_at, label_name = excluded.label_name,
                stamp_label_count = excluded.stamp_label_count, status = excluded.status,
                gmail_thread_id = excluded.gmail_thread_id
            """).execute(arguments: [tid, account, gmailThreadID, snooze.wakeAt, snooze.labelName, snooze.stampLabelCount,
                             snooze.status.rawValue])
    }

    private static func splitFacts(_ m: Message, context: AggregationContext) -> SplitFacts.Message {
        SplitFacts.Message(fromName: m.fromName, fromEmail: m.fromEmail, toJSON: m.toJSON, ccJSON: m.ccJSON,
                           labels: m.labels.filter { !(context.byKey[$0]?.hidden ?? false) }, isUnread: m.isUnread,
                           isFromMe: m.isFromMe, hasAttachments: m.hasAttachments,
                           hasCalendarInvite: m.hasCalendarInvite, listID: m.listID, subject: m.subject,
                           mid: m.mid, internalDate: m.internalDate,
                           _fromLower: context.readsSenders ? m.fromEmail?.lowercased() : nil)
    }
}
