import Foundation
import OpenHumanCore
import OpenHumanStore

public enum OpenHumanStoreTesting {
    public static let systemLabels: [LabelUpsert] = [
        "INBOX", "STARRED", "IMPORTANT", "UNREAD", "SENT", "DRAFT", "TRASH", "SPAM",
        "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS",
    ].map { LabelUpsert(gmailLabelID: GmailLabelID($0), name: $0, type: "system") }

    public static func storeWithAccount(email: String = "me@example.com") throws -> (MailStore, AccountID) {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: email, displayName: "Me", scopes: ["gmail.readonly"])
        try store.upsertLabels(systemLabels, account: account, removeMissing: false)
        return (store, account)
    }
}

extension MessageUpsert {
    public static func fixture(
        _ id: String, thread: String? = nil, minutes: Int = 0, labels: [String] = ["INBOX"],
        from: String = "alice@example.com", fromName: String? = "Alice Smith", to: [String] = ["me@example.com"],
        subject: String = "Hello", snippet: String = "snippet", history: UInt64 = 1, body: MessageBodyUpsert? = nil
    ) -> MessageUpsert {
        MessageUpsert(
            gmailMessageID: GmailMessageID(id), gmailThreadID: GmailThreadID(thread ?? "t-\(id)"),
            historyID: HistoryID(history),
            internalDate: Date(timeIntervalSince1970: 1_790_000_000 + Double(minutes) * 60),
            labelIDs: labels.map { GmailLabelID($0) }, snippet: snippet, sizeEstimate: 1000,
            headers: MessageHeaderFields(
                subject: subject, from: EmailAddress(name: fromName, email: from),
                to: to.map { EmailAddress(email: $0) }, cc: [], bcc: [], replyTo: [], date: nil,
                messageID: "<\(id)@example.com>", inReplyTo: nil, references: []),
            body: body)
    }
}

extension MessageBodyUpsert {
    public static func fixture(html: String? = "<p>Hi</p>", text: String? = "Hi") -> MessageBodyUpsert {
        MessageBodyUpsert(html: html, text: text, hasCalendarInvite: false, decodeWarnings: [], searchText: text ?? "")
    }
}
