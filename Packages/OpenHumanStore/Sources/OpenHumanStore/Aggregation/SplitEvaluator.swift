import Foundation
import GRDB
import OpenHumanCore

struct SplitFacts {
    struct Message {
        var fromName: String?
        var fromEmail: String?
        var toJSON: String
        var ccJSON: String
        var labels: Set<String>
        var isUnread: Bool
        var isFromMe: Bool
        var hasAttachments: Bool
        var hasCalendarInvite: Bool
        var listID: String?
        var subject: String
        var mid: Int64 = 0
        var internalDate: Int64 = 0
        var text: ImportanceText.Text?

        var fromLower: String? { _fromLower ?? fromEmail?.lowercased() }
        var _fromLower: String?
    }

    var messages: [Message]
    var gmailThreadID: String? = nil

    var recipients: [WireAddress] {
        messages.flatMap { WireAddress.decode($0.toJSON) + WireAddress.decode($0.ccJSON) }
    }
}

extension AggregationContext {
    func inboxSplitRids(_ placement: Placement) -> [Int64] {
        guard let holder = placement.splitRid else { return otherSplitRid.map { [$0] } ?? [] }
        if placement.importance == .important, !eventSplitRids.isEmpty {
            return [holder] + placement.chipRids.filter { eventSplitRids.contains($0) && $0 != holder }
        }
        guard placement.importance != .important, alsoShowInInboxRids.contains(holder), let other = otherSplitRid,
              other != holder else { return [holder] }
        return [holder, other]
    }
}

enum SplitEvaluator {
    static func split(for facts: SplitFacts, context: AggregationContext) -> Int64? {
        ImportanceEvaluator.place(facts, context: context).splitRid
    }

    static func matches(_ rule: SplitRule, _ facts: SplitFacts, _ labels: LabelMatcher) -> Bool {
        switch rule {
        case let .from(pattern):
            let p = AddressPattern(pattern)
            return facts.messages.contains { m in m.fromEmail.map { p.matches(email: $0, name: m.fromName) } ?? false }
        case let .to(pattern):
            let p = AddressPattern(pattern)
            return facts.recipients.contains { p.matches(email: $0.e, name: $0.n) }
        case let .label(nameOrID):
            let keys = labels.keys(matching: nameOrID)
            return !keys.isEmpty && facts.messages.contains { !$0.labels.isDisjoint(with: keys) }
        case let .category(name):
            let key = LabelMatcher.categoryKey(name)
            return facts.messages.contains { $0.labels.contains(key) }
        case .isImportant: return facts.messages.contains { $0.labels.contains("IMPORTANT") }
        case .isStarred: return facts.messages.contains { $0.labels.contains("STARRED") }
        case .isUnread: return facts.messages.contains(where: \.isUnread)
        case .hasAttachment: return facts.messages.contains(where: \.hasAttachments)
        case .hasCalendarInvite: return facts.messages.contains(where: \.hasCalendarInvite)
        case .isEvent: return facts.messages.contains { isEvent($0, labels) }
        case let .list(text):
            let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
            return !needle.isEmpty && facts.messages.contains { ($0.listID?.lowercased().contains(needle)) ?? false }
        case let .subjectContains(text):
            let needle = text.lowercased()
            return !needle.isEmpty && facts.messages.contains { $0.subject.lowercased().contains(needle) }
        case .fromMeOnly:
            return false
        case let .and(rules): return rules.allSatisfy { matches($0, facts, labels) }
        case let .or(rules): return rules.contains { matches($0, facts, labels) }
        case let .not(inner): return !matches(inner, facts, labels)
        }
    }

    static func isEvent(_ m: SplitFacts.Message, _ labels: LabelMatcher) -> Bool {
        if m.hasCalendarInvite { return true }
        if EventMailSignals.headersSuggestEvent(fromEmail: m.fromEmail, subject: m.subject) { return true }
        let keys = labels.context.eventLabelKeys
        return !keys.isEmpty && !m.labels.isDisjoint(with: keys)
    }
}

extension SplitRule {
    var isEventsOnlyRule: Bool {
        switch self {
        case .isEvent, .hasCalendarInvite: return true
        case let .or(items): return !items.isEmpty && items.allSatisfy(\.isEventsOnlyRule)
        default: return false
        }
    }
}

struct LabelMatcher {
    let context: AggregationContext

    func keys(matching nameOrID: String) -> Set<String> {
        let wanted = nameOrID.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return [] }
        var keys = Set<String>()
        for info in context.byKey.values where !info.hidden && info.kind != "virtual" && info.kind != "split" {
            if info.key.lowercased() == wanted || info.name.lowercased() == wanted { keys.insert(info.key) }
        }
        return keys
    }

    static func categoryKey(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return "CATEGORY_" + (n == "primary" ? "PERSONAL" : n.uppercased())
    }
}

struct AddressPattern {
    private enum Kind { case address(String), domain(String), text(String), nothing }
    private let kind: Kind

    init(_ raw: String) {
        let p = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if p.isEmpty || p == "@" { kind = .nothing }
        else if p.hasPrefix("@") { kind = .domain(String(p.dropFirst())) }
        else if p.contains("@") { kind = .address(p) }
        else if p.contains(".") { kind = .domain(p) }
        else { kind = .text(p) }
    }

    func matches(email: String, name: String?) -> Bool {
        let e = email.lowercased()
        switch kind {
        case .nothing: return false
        case let .address(a): return e == a
        case let .domain(d):
            guard let at = e.lastIndex(of: "@") else { return false }
            let domain = e[e.index(after: at)...]
            return domain == d || domain.hasSuffix("." + d)
        case let .text(t): return e.contains(t) || (name?.lowercased().contains(t) ?? false)
        }
    }
}

extension ThreadAggregator {
    @discardableResult
    static func reevaluateSplits(account: Int64, in db: Database) throws -> Int {
        let context = try AggregationContext.load(account: account, in: db)
        let splitRids = Set(context.splits.map(\.labelRid) + [context.otherSplitRid].compactMap { $0 })
        let allSplitRids = Set(try Int64.fetchAll(db, sql: "SELECT label_rid FROM labels WHERE account_id = ? AND kind = 'split'",
                                                  arguments: [account])).union(splitRids)

        struct Current {
            var splitRid: Int64?
            var importance: String
            var reasonRid: Int64?
            var chips: String
            var gmailThreadID: String?
            var rows: [(rid: Int64, sortAt: Int64, unread: Bool)] = []
        }
        var current: [Int64: Current] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT tid, split_rid, importance, importance_reason_rid, split_chip_rids, gmail_thread_id FROM threads
            WHERE account_id = ? AND in_inbox = 1
            """, arguments: [account]) {
            current[r["tid"]] = Current(splitRid: r["split_rid"], importance: r["importance"], reasonRid: r["importance_reason_rid"],
                                        chips: r["split_chip_rids"], gmailThreadID: r["gmail_thread_id"])
        }
        guard !current.isEmpty else { return 0 }
        for r in try Row.fetchAll(db, sql: """
            SELECT tl.tid, tl.label_rid, tl.sort_at, tl.unread FROM thread_labels tl
            JOIN labels l ON l.label_rid = tl.label_rid
            WHERE l.account_id = ? AND l.kind = 'split'
            """, arguments: [account]) {
            let tid: Int64 = r["tid"]
            guard var entry = current[tid], allSplitRids.contains(r["label_rid"]) else { continue }
            entry.rows.append((r["label_rid"], r["sort_at"], r["unread"]))
            current[tid] = entry
        }

        var facts: [Int64: [SplitFacts.Message]] = [:]
        let reminderRule = context.superhumanReminders
        var reminderCandidates: [Int64: [SuperhumanReminderRule.Candidate]] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT m.mid, m.gmail_message_id, m.internal_date, m.tid, m.from_name, m.from_email, m.to_json, m.cc_json,
                   m.label_ids, m.is_unread, m.is_from_me, m.has_attachments, m.has_calendar_invite, m.list_id, m.subject
            FROM messages m JOIN threads t ON t.tid = m.tid
            WHERE t.account_id = ? AND t.in_inbox = 1 AND m.is_draft = 0 AND m.in_trash = 0 AND m.in_spam = 0
            """, arguments: [account]) {
            facts[r["tid"], default: []].append(splitMessage(r, context: context, lowercaseSender: context.readsSenders))
            if reminderRule.isActive {
                let labels = Labels.split(r["label_ids"])
                reminderCandidates[r["tid"], default: []].append(SuperhumanReminderRule.Candidate(
                    mid: r["mid"], gmailID: r["gmail_message_id"], internalDate: r["internal_date"],
                    fromEmail: r["from_email"], isFromMe: r["is_from_me"], isDraft: false, inTrash: false, inSpam: false,
                    hasAttachments: r["has_attachments"], hasCalendarInvite: r["has_calendar_invite"],
                    inInbox: labels.contains("INBOX")))
            }
        }
        for (tid, candidates) in reminderCandidates {
            let hidden = reminderRule.hiddenMids(candidates)
            if !hidden.isEmpty { facts[tid]?.removeAll { hidden.contains($0.mid) } }
        }
        let texts = context.readsText ? try ImportanceText.loadInbox(account: account, in: db) : [:]

        var moved = 0
        var repair = Set<Int64>()
        let now = nowMillis()
        let update = try db.cached("""
            UPDATE threads SET split_rid = ?, importance = ?, importance_reason_rid = ?, split_chip_rids = ?, updated_at = ?
            WHERE tid = ?
            """)
        for (tid, entry) in current {
            guard let row = entry.rows.first, entry.rows.allSatisfy({ $0.sortAt == row.sortAt }) else {
                repair.insert(tid)
                continue
            }
            var messages = facts[tid] ?? []
            if context.readsText { for i in messages.indices { messages[i].text = texts[messages[i].mid] } }
            let placement = ImportanceEvaluator.place(SplitFacts(messages: messages, gmailThreadID: entry.gmailThreadID),
                                                      context: context)
            let wantRids = Set(context.inboxSplitRids(placement))
            let haveRids = Set(entry.rows.map(\.rid))
            let chips = placement.chipText
            let importance = placement.importance.rawValue
            let changed = placement.splitRid != entry.splitRid || importance != entry.importance
                || placement.reasonRid != entry.reasonRid || chips != entry.chips
            if !changed && haveRids == wantRids && entry.rows.count == haveRids.count { continue }
            moved += 1
            if changed {
                try update.execute(arguments: [placement.splitRid, importance, placement.reasonRid, chips, now, tid])
            }
            var kept = Set<Int64>()
            for have in entry.rows {
                if wantRids.contains(have.rid), kept.insert(have.rid).inserted { continue }
                try db.cached("DELETE FROM thread_labels WHERE label_rid = ? AND sort_at = ? AND tid = ?")
                    .execute(arguments: [have.rid, have.sortAt, tid])
            }
            for wantRid in wantRids.subtracting(kept) {
                try db.cached("INSERT INTO thread_labels (label_rid, sort_at, tid, unread) VALUES (?, ?, ?, ?)")
                    .execute(arguments: [wantRid, row.sortAt, tid, row.unread])
            }
        }
        if !repair.isEmpty { try refresh(tids: repair, in: db) }
        return moved + repair.count
    }

    static func splitMessage(_ r: Row, context: AggregationContext, lowercaseSender: Bool = false) -> SplitFacts.Message {
        let labels = Labels.split(r["label_ids"]).filter { !(context.byKey[$0]?.hidden ?? false) }
        return SplitFacts.Message(fromName: r["from_name"], fromEmail: r["from_email"], toJSON: r["to_json"],
                                  ccJSON: r["cc_json"], labels: labels, isUnread: r["is_unread"], isFromMe: r["is_from_me"],
                                  hasAttachments: r["has_attachments"], hasCalendarInvite: r["has_calendar_invite"],
                                  listID: r["list_id"], subject: r["subject"], mid: r["mid"], internalDate: r["internal_date"],
                                  _fromLower: lowercaseSender ? (r["from_email"] as String?)?.lowercased() : nil)
    }
}
