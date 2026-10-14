import Foundation
import MailModel
import OpenHumanCore
import OpenHumanLinks

public struct IntentAccount: Hashable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct IntentThread: Hashable, Sendable {
    public let id: String
    public let link: URL
    public let senderName: String
    public let date: Date
    public let isImportant: Bool
    public let isUnread: Bool
    public let accountName: String
    public let subject: String

    public init(id: String, link: URL, senderName: String, date: Date, isImportant: Bool, isUnread: Bool,
                accountName: String, subject: String) {
        self.id = id
        self.link = link
        self.senderName = senderName
        self.date = date
        self.isImportant = isImportant
        self.isUnread = isUnread
        self.accountName = accountName
        self.subject = subject
    }

    public var title: String { subject.isEmpty ? "Mail from \(senderName)" : subject }
}

public struct IntentRowFacts: Sendable {
    public let key: ThreadKey
    public let subject: String
    public let senderName: String?
    public let onlyMe: Bool
    public let date: Date
    public let isImportant: Bool
    public let isUnread: Bool

    public init(_ row: ThreadRow) {
        key = row.id
        subject = row.subject
        let other = row.participants.first { !$0.isMe }
        senderName = other?.name
        onlyMe = other == nil
        date = row.lastMessageAt
        isImportant = row.isImportant
        isUnread = row.isUnread
    }
}

public enum IntentEntityBuilder {
    public static let unknownSender = "Unknown sender"

    public static func account(_ account: Account) -> IntentAccount {
        IntentAccount(id: String(account.id.rawValue), title: accountTitle(account))
    }

    public static func accountTitle(_ account: Account) -> String {
        if let alias = account.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty { return alias }
        return account.email
    }

    public static func thread(_ facts: IntentRowFacts, account: Account, includeSubjects: Bool) -> IntentThread {
        let link = MailLinkBuilder.url(for: .thread(account: AccountRef(account.email),
                                                    threadID: facts.key.gmailThreadID.rawValue))
        return IntentThread(id: SpotlightIdentifier.make(facts.key), link: link,
                            senderName: facts.onlyMe ? "Me" : senderName(facts.senderName), date: facts.date,
                            isImportant: facts.isImportant, isUnread: facts.isUnread,
                            accountName: accountTitle(account), subject: includeSubjects ? facts.subject : "")
    }

    public static func senderName(_ name: String?) -> String {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !name.contains("@") else {
            return unknownSender
        }
        return name
    }
}
