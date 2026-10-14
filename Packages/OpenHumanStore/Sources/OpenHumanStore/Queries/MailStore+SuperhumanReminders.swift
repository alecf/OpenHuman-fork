import Foundation
import GRDB
import OpenHumanCore

extension MailStore {
    public func superhumanReminderEmails(account: AccountID, limit: Int) throws -> [SuperhumanReminderEmailItem] {
        try read { db in try Self.superhumanReminderItems(account: account.rawValue, limit: limit, in: db) }
    }

    static func superhumanReminderItems(account: Int64, limit: Int, in db: Database) throws -> [SuperhumanReminderEmailItem] {
        let rule = try SuperhumanReminderRule.load(account: account, in: db)
        guard limit > 0, !rule.senders.isEmpty else { return [] }
        var rows: [Row] = []
        for sender in rule.senders.sorted() {
            rows += try Row.fetchAll(db.cached("""
                SELECT mid, tid, gmail_message_id, internal_date, in_reply_to, references_ids
                FROM messages WHERE account_id = ? AND from_email = ? ORDER BY internal_date DESC, mid DESC LIMIT ?
                """), arguments: [account, sender, limit])
        }
        rows.sort { ($0["internal_date"] as Int64, $0["mid"] as Int64) > ($1["internal_date"] as Int64, $1["mid"] as Int64) }

        struct Conversation {
            var candidates: [SuperhumanReminderRule.Candidate]
            var hidden: Set<Int64>
            var ref: ThreadRef
            var subject: String
            var inInbox: Bool
        }
        var conversations: [Int64: Conversation] = [:]
        var items: [SuperhumanReminderEmailItem] = []
        for row in rows where items.count < limit {
            let mid: Int64 = row["mid"]
            let tid: Int64 = row["tid"]
            if conversations[tid] == nil {
                guard let thread = try Row.fetchOne(db.cached("""
                    SELECT gmail_thread_id, subject, in_inbox FROM threads WHERE tid = ?
                    """), arguments: [tid]) else { continue }
                let candidates = try ThreadAggregator.loadMessages(tid: tid, in: db).map { SuperhumanReminderRule.Candidate($0) }
                conversations[tid] = Conversation(
                    candidates: candidates, hidden: rule.hiddenMids(candidates),
                    ref: ThreadRef(accountID: AccountID(account), rowID: ThreadRowID(rawValue: tid),
                                   gmailThreadID: GmailThreadID(thread["gmail_thread_id"] as String)),
                    subject: thread["subject"], inInbox: thread["in_inbox"])
            }
            guard let conversation = conversations[tid],
                  let candidate = conversation.candidates.first(where: { $0.mid == mid }),
                  rule.isReminderEmail(candidate) else { continue }
            let detected = Set(conversation.candidates.filter(rule.isReminderEmail).map(\.mid))
            let hasOtherMail = conversation.candidates.contains { $0.isVisible && !detected.contains($0.mid) }
            var match = SuperhumanReminderMatch.unmatched
            var subject = conversation.subject
            var targetInInbox = conversation.inInbox
            if hasOtherMail {
                match = .sameConversation
            } else if let target = try headerTarget(account: account, inReplyTo: row["in_reply_to"],
                                                    references: row["references_ids"], excluding: tid, in: db) {
                match = .replyHeaders(target: target.ref)
                subject = target.subject
                targetInInbox = target.inInbox
            }
            items.append(SuperhumanReminderEmailItem(
                message: MessageRowID(rawValue: mid), gmailMessageID: GmailMessageID(candidate.gmailID),
                thread: conversation.ref, date: Date(timeIntervalSince1970: Double(candidate.internalDate) / 1000),
                isInInbox: candidate.inInbox, isHidden: conversation.hidden.contains(mid), match: match,
                subject: subject, targetInInbox: targetInInbox))
        }
        return items
    }

    private static func headerTarget(account: Int64, inReplyTo: String?, references: String?, excluding tid: Int64,
                                     in db: Database) throws -> (ref: ThreadRef, subject: String, inInbox: Bool)? {
        var ids: [String] = []
        if let inReplyTo, !inReplyTo.isEmpty { ids.append(inReplyTo) }
        ids += (references ?? "").split(separator: " ").map(String.init).reversed()
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted {
            if let r = try Row.fetchOne(db.cached("""
                SELECT t.tid, t.gmail_thread_id, t.subject, t.in_inbox FROM messages m JOIN threads t ON t.tid = m.tid
                WHERE m.account_id = ? AND m.rfc822_message_id = ? AND m.tid <> ? AND m.in_trash = 0 AND m.in_spam = 0
                LIMIT 1
                """), arguments: [account, id, tid]) {
                let ref = ThreadRef(accountID: AccountID(account), rowID: ThreadRowID(rawValue: r["tid"]),
                                    gmailThreadID: GmailThreadID(r["gmail_thread_id"] as String))
                let subject: String = r["subject"]
                let inInbox: Bool = r["in_inbox"]
                return (ref, subject, inInbox)
            }
        }
        return nil
    }

    static func hiddenReminderMessages(tid: Int64, account: Int64, in db: Database) throws -> [MessageRowID] {
        let rule = try SuperhumanReminderRule.load(account: account, in: db)
        guard rule.isActive else { return [] }
        let candidates = try ThreadAggregator.loadMessages(tid: tid, in: db).map { SuperhumanReminderRule.Candidate($0) }
        return rule.hiddenMids(candidates).sorted().map { MessageRowID(rawValue: $0) }
    }
}
