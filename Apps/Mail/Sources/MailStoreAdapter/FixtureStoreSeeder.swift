#if DEBUG || OH_DEV_TOOLS
import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanStore

public enum FixtureStoreSeeder {
    static let systemLabels: [LabelUpsert] = [
        "INBOX", "STARRED", "IMPORTANT", "UNREAD", "SENT", "DRAFT", "TRASH", "SPAM",
        "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS",
    ].map { LabelUpsert(gmailLabelID: GmailLabelID($0), name: $0, type: "system") }

    public static func makeStore(corpus: FakeCorpus, withBodies: Bool = true) throws -> (MailStore, AccountID) {
        let store = try MailStore.openInMemoryForTesting()
        let account = try seed(store, corpus: corpus, withBodies: withBodies)
        return (store, account)
    }

    @discardableResult
    public static func seed(_ store: MailStore, corpus: FakeCorpus, withBodies: Bool = true) throws -> AccountID {
        let account = try store.addAccount(email: corpus.account.email, displayName: corpus.account.displayName,
                                           scopes: ["gmail.readonly"])
        try store.upsertLabels(systemLabels, account: account, removeMissing: false)
        var history: UInt64 = 1
        var upserts: [MessageUpsert] = []
        for thread in corpus.threads {
            for message in thread.detail.messages {
                history += 1
                upserts.append(upsert(message, thread: thread, history: history, withBody: withBodies))
            }
        }
        _ = try store.upsertMessages(upserts, account: account, generation: 1)
        return account
    }

    static func labels(_ message: MessageSummary, thread: FakeCorpus.Thread) -> [GmailLabelID] {
        let fromMe = message.from?.email == FakeCorpus.me.email
        var labels = fromMe ? ["SENT"] : ["INBOX"]
        if fromMe, thread.row.messageCount > 1 { labels.append("INBOX") }
        if message.isUnread { labels.append("UNREAD") }
        if thread.row.isStarred, message.id == thread.detail.messages.last?.id { labels.append("STARRED") }
        if thread.row.isImportant { labels.append("IMPORTANT") }
        labels += (thread.labels[message.id] ?? []).map(\.rawValue).filter { $0.hasPrefix("CATEGORY_") }
        return labels.map { GmailLabelID($0) }
    }

    static func upsert(_ message: MessageSummary, thread: FakeCorpus.Thread, history: UInt64, withBody: Bool) -> MessageUpsert {
        let labels = Self.labels(message, thread: thread)
        let content = thread.bodies[message.id]
        let body = withBody ? content.map {
            MessageBodyUpsert(html: $0.html, text: $0.text, hasCalendarInvite: false, decodeWarnings: [],
                              searchText: $0.text ?? "")
        } : nil
        let unsubscribe = thread.unsubscribe[message.id].map(listUnsubscribe)
        return MessageUpsert(
            gmailMessageID: message.id.gmailMessageID, gmailThreadID: thread.row.id.gmailThreadID,
            historyID: HistoryID(history), internalDate: message.date, labelIDs: labels,
            snippet: message.snippet, sizeEstimate: 2_000,
            headers: MessageHeaderFields(
                subject: thread.detail.subject, from: message.from, to: message.to, cc: message.cc, bcc: message.bcc,
                replyTo: [], date: message.date, messageID: "<\(message.id.gmailMessageID.rawValue)@fake.example>",
                inReplyTo: nil, references: [], listUnsubscribe: unsubscribe?.header,
                listUnsubscribePost: unsubscribe?.post),
            body: body,
            attachments: message.attachments.enumerated().map { index, info in
                AttachmentUpsert(partID: "\(index + 1)", filename: info.filename, mimeType: info.mimeType, size: info.size,
                                 contentID: info.contentID, isInline: info.isInline)
            })
    }

    static func listUnsubscribe(_ info: UnsubscribeInfo) -> (header: String, post: String?) {
        switch info {
        case .oneClick(let host):
            return ("<https://\(host)/unsubscribe/one-click>", ListUnsubscribe.oneClickValue)
        case .mailto(let address, let subject):
            let query = subject.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }
            return ("<mailto:\(address.email)\(query.map { "?subject=\($0)" } ?? "")>", nil)
        case .link(let url):
            return ("<\(url.absoluteString)>", nil)
        }
    }

    @discardableResult
    public static func seedLargeInbox(_ store: MailStore, count: Int, now: Date = Date()) throws -> AccountID {
        let account = try store.addAccount(email: "large@example.com", displayName: "Large inbox", scopes: ["gmail.readonly"])
        try store.upsertLabels(systemLabels, account: account, removeMissing: false)
        var upserts: [MessageUpsert] = []
        upserts.reserveCapacity(count)
        for index in 0..<count {
            var labels = ["INBOX"]
            if index % 3 == 0 { labels.append("UNREAD") }
            if index % 5 == 0 { labels.append("CATEGORY_PROMOTIONS") } else if index % 7 == 0 { labels.append("CATEGORY_UPDATES") }
            let date = now.addingTimeInterval(-Double(index) * 600)
            upserts.append(MessageUpsert(
                gmailMessageID: GmailMessageID(String(format: "lm%06d", index)),
                gmailThreadID: GmailThreadID(String(format: "lt%06d", index)),
                historyID: HistoryID(UInt64(index + 1)), internalDate: date, labelIDs: labels.map { GmailLabelID($0) },
                snippet: "Synthetic message \(index)", sizeEstimate: 1_000,
                headers: MessageHeaderFields(
                    subject: "Synthetic thread \(index)",
                    from: EmailAddress(name: "Sender \(index % 40)", email: "sender\(index % 40)@example.com"),
                    to: [EmailAddress(email: "large@example.com")], cc: [], bcc: [], replyTo: [], date: date,
                    messageID: "<lm\(index)@fake.example>", inReplyTo: nil, references: [])))
        }
        for start in stride(from: 0, to: upserts.count, by: 1_000) {
            _ = try store.upsertMessages(Array(upserts[start..<min(start + 1_000, upserts.count)]), account: account,
                                         generation: 1)
        }
        return account
    }
}
#endif
