import Foundation
import MailModel
import OpenHumanCore
import OpenHumanLinks

public enum SpotlightIdentifier {
    static let threadPrefix = "oh.thread."
    static let domainPrefix = "oh.account."

    public static func make(_ key: ThreadKey) -> String {
        "\(threadPrefix)\(key.account.rawValue).\(key.gmailThreadID.rawValue)"
    }

    public static func domain(_ account: AccountID) -> String { "\(domainPrefix)\(account.rawValue)" }

    public static func parse(_ identifier: String) -> (account: AccountID, thread: GmailThreadID)? {
        guard identifier.hasPrefix(threadPrefix) else { return nil }
        let parts = identifier.dropFirst(threadPrefix.count).split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let account = Int64(parts[0]), !parts[1].isEmpty else { return nil }
        return (AccountID(account), GmailThreadID(String(parts[1])))
    }

    public static func deepLink(for identifier: String, accounts: [Account]) -> URL? {
        guard let parsed = parse(identifier), let account = accounts.first(where: { $0.id == parsed.account }) else { return nil }
        return MailLinkBuilder.url(for: .thread(account: AccountRef(account.email), threadID: parsed.thread.rawValue))
    }
}

@MainActor
enum SpotlightItemBuilder {
    static func item(for row: ThreadRow, labelNames: [Int64: String], includeSubjects: Bool) -> SpotlightItem {
        let sender = NotificationService.sender(of: row)
        let categories = row.categoryLabelIDs.compactMap { labelNames[$0] }
        let labels = row.userLabelIDs.compactMap { labelNames[$0] }
        var keywords = categories + labels
        if row.isImportant { keywords.insert("Important", at: 0) }
        let facts = keywords.joined(separator: " · ")
        let title: String
        let summary: String
        if includeSubjects {
            title = row.subject.isEmpty ? "Mail from \(sender)" : row.subject
            summary = row.snippet
        } else {
            title = "Mail from \(sender)"
            summary = facts.isEmpty ? "Mail" : facts
        }
        return SpotlightItem(identifier: SpotlightIdentifier.make(row.id), domain: SpotlightIdentifier.domain(row.id.account),
                             title: title, summary: summary, authorName: sender, date: row.lastMessageAt, keywords: keywords,
                             isImportant: row.isImportant)
    }
}
