import Foundation
import OpenHumanCore
import OpenHumanLinks
import OpenHumanMIME
import OpenHumanStore

final class Mapper {
    private let store: MailStore
    private var accountEmails: [AccountID: String] = [:]
    private var books: [AccountID: [LabelItem]] = [:]

    init(store: MailStore) throws {
        self.store = store
        for account in try store.accounts() { accountEmails[account.id] = account.email }
    }

    func email(_ id: AccountID) -> String { accountEmails[id] ?? "unknown" }

    private func labels(_ account: AccountID) -> [LabelItem] {
        if let cached = books[account] { return cached }
        let list = (try? store.labels(account: account)) ?? []
        books[account] = list
        return list
    }

    static func isHidden(_ label: LabelItem) -> Bool {
        label.isHidden || ScheduleLabel.parse(label.name) != .notOurs
    }

    func labelName(_ key: String, account: AccountID) -> String? {
        guard let label = labels(account).first(where: { $0.key == key }) else { return key }
        if Self.isHidden(label) { return nil }
        return label.kind == .user ? label.name : label.key
    }

    func labelNames(_ keys: [GmailLabelID], account: AccountID) -> [String] {
        keys.compactMap { labelName($0.rawValue, account: account) }
    }

    func threadLink(_ account: AccountID, _ thread: GmailThreadID) -> String {
        MailLinkBuilder.url(for: .thread(account: AccountRef(email(account)), threadID: thread.rawValue)).absoluteString
    }

    func draftLink(_ draft: DraftListItem) -> String {
        MailLinkBuilder.url(for: .draft(account: AccountRef(email(draft.accountID)), draftID: draft.id.rawValue)).absoluteString
    }

    func reviewLink(_ drafts: [DraftListItem]) -> String {
        MailLinkBuilder.url(for: .review(drafts.map { DraftRef(account: AccountRef(email($0.accountID)), draftID: $0.id.rawValue) })).absoluteString
    }

    func address(_ a: EmailAddress) -> OutValue {
        obj(["name": OutValue.optUntrusted(a.name), "email": .string(a.email)])
    }

    func thread(_ item: ThreadListItem, extraLabels: [String] = [], split: String? = nil) -> OutValue {
        let account = item.ref.accountID
        var names = labelNames(store.userLabelKeys(item.userLabelIDs, labels(account)) + store.userLabelKeys(item.categoryLabelIDs, labels(account)),
                               account: account)
        for (flag, name) in [(item.isUnread, "UNREAD"), (item.isStarred, "STARRED"), (item.isImportant, "IMPORTANT")] where flag {
            names.append(name)
        }
        for extra in extraLabels where !names.contains(extra) { names.append(extra) }
        return obj([
            "account": .string(email(account)),
            "threadId": .string(item.ref.gmailThreadID.rawValue),
            "subject": .untrusted(item.subject),
            "snippet": .untrusted(item.snippet),
            "participants": .array(item.participants.map { p in
                obj(["name": OutValue.optUntrusted(p.name), "email": .string(p.email), "isMe": .bool(p.isMe)])
            }),
            "messageCount": .int(item.messageCount),
            "unread": .bool(item.isUnread),
            "starred": .bool(item.isStarred),
            "important": .bool(item.isImportant),
            "hasAttachments": .bool(item.attachmentCount > 0),
            "hasDraft": .bool(item.draftCount > 0),
            "labels": .array(names.map { .untrusted($0) }),
            "lastMessageAt": OutValue.date(item.lastMessageAt),
            "snoozedUntil": OutValue.optDate(item.snoozedUntil),
            "reminderAt": OutValue.optDate(item.reminderAt),
            "scheduledSendAt": OutValue.optDate(item.scheduledSendAt),
            "split": OutValue.optUntrusted(split),
            "link": .string(threadLink(account, item.ref.gmailThreadID)),
        ])
    }

    func fromColumn(_ item: ThreadListItem) -> OutValue {
        let sender = item.participants.first { !$0.isMe } ?? item.participants.first
        return .untrusted(sender?.name ?? sender?.email ?? "")
    }

    func threadRow(_ item: ThreadListItem) -> [OutValue] {
        [.string(item.ref.gmailThreadID.rawValue), .string(email(item.ref.accountID)), OutValue.date(item.lastMessageAt),
         .bool(item.isUnread), fromColumn(item), .untrusted(item.subject), .untrusted(item.snippet),
         .string(threadLink(item.ref.accountID, item.ref.gmailThreadID))]
    }

    enum BodyDetail { case none, text, html }

    func message(_ m: MessageItem, account: AccountID, thread: GmailThreadID, body: MessageBody?, detail: BodyDetail,
                 headers: [String]? = nil, includeHeaders: Bool = false) -> (value: OutValue, bodyMissing: Bool) {
        var bodyValue: OutValue?
        var missing = false
        if detail != .none {
            let text = body.flatMap { Self.bodyText($0) }
            let available = body != nil && (text != nil || body?.html != nil)
            missing = !available
            var fields: [String: OutValue] = ["bodyAvailable": .bool(available)]
            if let text { fields["text"] = .body(text) }
            if detail == .html, let html = body?.html { fields["html"] = .body(html) }
            bodyValue = .object(fields)
        }
        var headerList: OutValue?
        if includeHeaders || headers != nil {
            var pairs = Self.headerPairs(m)
            if let wanted = headers?.map({ $0.lowercased() }), !wanted.isEmpty {
                pairs = pairs.filter { wanted.contains($0.0.lowercased()) }
            }
            headerList = .array(pairs.map { obj(["name": .string($0.0), "value": .untrusted($0.1)]) })
        }
        let value = obj([
            "account": .string(email(account)),
            "messageId": .string(m.gmailMessageID.rawValue),
            "threadId": .string(thread.rawValue),
            "date": OutValue.date(m.date),
            "from": m.from.map(address),
            "to": .array(m.to.map(address)),
            "cc": .array(m.cc.map(address)),
            "bcc": .array(m.bcc.map(address)),
            "replyTo": .array(m.replyTo.map(address)),
            "subject": .untrusted(m.subject),
            "snippet": .untrusted(m.snippet),
            "labels": .array(labelNames(m.labelIDs, account: account).map { .untrusted($0) }),
            "unread": .bool(m.isUnread),
            "isDraft": .bool(m.isDraft),
            "rfc822MessageId": OutValue.optString(m.rfc822MessageID),
            "inReplyTo": OutValue.optString(m.inReplyTo),
            "references": .strings(m.references),
            "listUnsubscribe": OutValue.optUntrusted(m.listUnsubscribe),
            "attachments": .array(m.attachments.map { a in
                obj(["partId": .string(a.partID), "filename": .untrusted(a.filename), "mimeType": .string(a.mimeType),
                     "size": .int(a.size), "inline": .bool(a.isInline)])
            }),
            "body": bodyValue,
            "headers": headerList,
            "link": .string(threadLink(account, thread)),
        ])
        return (value, missing)
    }

    static func bodyText(_ body: MessageBody) -> String? {
        if let text = body.text, !text.isEmpty { return text }
        if let html = body.html, !html.isEmpty { return HTMLText.extract(html) }
        return nil
    }

    static func headerPairs(_ m: MessageItem) -> [(String, String)] {
        func list(_ a: [EmailAddress]) -> String { a.map { addr in addr.name.map { "\($0) <\(addr.email)>" } ?? addr.email }.joined(separator: ", ") }
        var pairs: [(String, String)] = []
        if let from = m.from { pairs.append(("From", list([from]))) }
        if !m.to.isEmpty { pairs.append(("To", list(m.to))) }
        if !m.cc.isEmpty { pairs.append(("Cc", list(m.cc))) }
        if !m.replyTo.isEmpty { pairs.append(("Reply-To", list(m.replyTo))) }
        pairs.append(("Subject", m.subject))
        pairs.append(("Date", OutValue.iso(m.headerDate ?? m.date)))
        if let id = m.rfc822MessageID { pairs.append(("Message-ID", id)) }
        if let reply = m.inReplyTo { pairs.append(("In-Reply-To", reply)) }
        if !m.references.isEmpty { pairs.append(("References", m.references.joined(separator: " "))) }
        if let unsub = m.listUnsubscribe { pairs.append(("List-Unsubscribe", unsub)) }
        return pairs
    }

    func draft(_ d: DraftListItem) -> OutValue {
        let agentOwned = d.origin != .user
        let text = d.content.bodyText ?? HTMLText.extract(d.content.bodyHTML)
        return obj([
            "account": .string(email(d.accountID)),
            "draftId": .string(d.id.rawValue),
            "gmailDraftId": OutValue.optString(d.gmailDraftID?.rawValue),
            "threadId": OutValue.optString(d.thread?.gmailThreadID.rawValue ?? d.gmailThreadID?.rawValue),
            "mode": .string(d.composeMode.rawValue),
            "origin": .string(d.origin.rawValue),
            "review": .string(d.reviewState.rawValue),
            "state": .string(d.state.rawValue),
            "sendAt": OutValue.optDate(d.sendAt),
            "to": .array(d.content.to.map(address)),
            "cc": .array(d.content.cc.map(address)),
            "bcc": .array(d.content.bcc.map(address)),
            "subject": .untrusted(d.content.subject),
            "bodyText": .body(text),
            "agentNote": OutValue.optUntrusted(d.agentNote),
            "updatedAt": OutValue.date(d.updatedAt),
            "link": .string(draftLink(d)),
            "reviewLink": agentOwned ? .string(reviewLink([d])) : nil,
        ])
    }

    func draftRow(_ d: DraftListItem) -> [OutValue] {
        [.string(d.id.rawValue), .string(email(d.accountID)), .string(d.origin.rawValue), .string(d.reviewState.rawValue),
         .string(d.state.rawValue), .array(d.content.to.map { .string($0.email) }), .untrusted(d.content.subject),
         .string(d.origin != .user ? reviewLink([d]) : "")]
    }
}

extension MailStore {
    func userLabelKeys(_ rows: [LabelRowID], _ labels: [LabelItem]) -> [GmailLabelID] {
        let byRow = Dictionary(labels.map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        return rows.compactMap { byRow[$0] }.map { GmailLabelID($0) }
    }
}
