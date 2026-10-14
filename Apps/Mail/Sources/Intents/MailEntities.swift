import AppIntents
import Foundation
import MailFeatures

struct AccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mail account"
    static let defaultQuery = AccountQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(_ account: IntentAccount) {
        self.init(id: account.id, title: account.title)
    }
}

struct AccountQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [AccountEntity.ID]) async throws -> [AccountEntity] {
        try await IntentBridge.current.accounts().filter { identifiers.contains($0.id) }.map { AccountEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [AccountEntity] {
        try await IntentBridge.current.accounts().map { AccountEntity($0) }
    }
}

struct ThreadEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Conversation"
    static let defaultQuery = ThreadQuery()

    let id: String
    @Property(title: "Link") var link: URL
    @Property(title: "Sender") var senderName: String
    @Property(title: "Date") var date: Date
    @Property(title: "Important") var isImportant: Bool
    @Property(title: "Unread") var isUnread: Bool
    @Property(title: "Account") var accountName: String
    @Property(title: "Subject") var subject: String

    var displayRepresentation: DisplayRepresentation {
        let title = subject.isEmpty ? "Mail from \(senderName)" : subject
        return DisplayRepresentation(title: "\(title)",
                                     subtitle: "\(date.formatted(date: .abbreviated, time: .shortened)) · \(accountName)")
    }

    init(_ thread: IntentThread) {
        id = thread.id
        link = thread.link
        senderName = thread.senderName
        date = thread.date
        isImportant = thread.isImportant
        isUnread = thread.isUnread
        accountName = thread.accountName
        subject = thread.subject
    }
}

struct ThreadQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [ThreadEntity.ID]) async throws -> [ThreadEntity] {
        try await IntentBridge.current.threads(for: identifiers).map { ThreadEntity($0) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ThreadEntity] {
        try await IntentBridge.current.threads(matching: string).map { ThreadEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ThreadEntity] {
        try await IntentBridge.current.suggestedThreads().map { ThreadEntity($0) }
    }
}

enum UnreadKindAppEnum: String, AppEnum {
    case important, inbox

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Unread mail"
    static let caseDisplayRepresentations: [UnreadKindAppEnum: DisplayRepresentation] = [
        .important: "Important",
        .inbox: "Inbox",
    ]

    var value: IntentUnreadKind {
        switch self {
        case .important: .important
        case .inbox: .inbox
        }
    }
}

enum MailboxAppEnum: String, AppEnum {
    case inbox, important, starred, drafts, sent, allMail, snoozed, reminders, scheduled, reviewQueue, muted

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mailbox"
    static let caseDisplayRepresentations: [MailboxAppEnum: DisplayRepresentation] = [
        .inbox: "Inbox",
        .important: "Important",
        .starred: "Starred",
        .drafts: "Drafts",
        .sent: "Sent",
        .allMail: "All mail",
        .snoozed: "Snoozed",
        .reminders: "Reminders",
        .scheduled: "Scheduled",
        .reviewQueue: "Review queue",
        .muted: "Muted",
    ]

    var value: IntentMailbox { IntentMailbox(rawValue: rawValue) ?? .inbox }
}
