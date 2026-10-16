import Foundation
import OpenHumanCore

public struct StoreOptions: Sendable {   // no-generated-init
    public var location: StoreLocation
    public var processKind: ProcessKind
    public var readOnly: Bool
    public var observeExternalChanges: Bool
    public var appVersion: String
    public var changeNotificationName: String
    public var pollOnly: Bool
    public init(location: StoreLocation, processKind: ProcessKind, readOnly: Bool = false,
                observeExternalChanges: Bool = false, appVersion: String,
                changeNotificationName: String = OHIdentifiers.storeChangedNotification, pollOnly: Bool = false) {
        self.location = location
        self.processKind = processKind
        self.readOnly = readOnly
        self.observeExternalChanges = observeExternalChanges
        self.appVersion = appVersion
        self.changeNotificationName = changeNotificationName
        self.pollOnly = pollOnly
    }
}
public enum ProcessKind: String, Sendable { case app, cli, test }

public enum StoreFileProtection: String, Sendable, Hashable {
    case untilFirstUnlock
}

public struct StoreFilePolicy: Sendable, Hashable {
    public var protection: StoreFileProtection?
    public var excludesStoreFromBackup: Bool

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        protection: StoreFileProtection? = nil,
        excludesStoreFromBackup: Bool
    ) {
        self.protection = protection
        self.excludesStoreFromBackup = excludesStoreFromBackup
    }
    // end generated-init
}

public struct StoreLocation: Sendable, Hashable {
    public var directory: URL
    public var files: StoreFilePolicy = .platformDefault
    public var databaseURL: URL { directory.appendingPathComponent("mail.sqlite") }
    public var attachmentsDirectory: URL { directory.appendingPathComponent("Attachments", isDirectory: true) }
    public var draftsDirectory: URL { directory.appendingPathComponent("Drafts", isDirectory: true) }
    public var snippetFilesDirectory: URL { directory.appendingPathComponent("Snippets", isDirectory: true) }

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        directory: URL,
        files: StoreFilePolicy = .platformDefault
    ) {
        self.directory = directory
        self.files = files
    }
    // end generated-init
}

public protocol MailReading: Sendable {
    func accounts() throws -> [AccountItem]
    func account(matching emailOrAlias: String) throws -> AccountItem?
    func labels(account: AccountID) throws -> [LabelItem]
    func label(account: AccountID, key: String) throws -> LabelItem?
    func splits(account: AccountID) throws -> [SplitItem]

    func threadPage(view: MailboxView, after: ThreadCursor?, limit: Int) throws -> ThreadPage
    func thread(_ ref: ThreadRef) throws -> ThreadListItem?
    func thread(account: AccountID, gmailThreadID: GmailThreadID) throws -> ThreadRef?

    func threadDetail(_ id: ThreadRowID) throws -> ThreadDetail?
    func message(account: AccountID, gmailMessageID: GmailMessageID) throws -> MessageItem?
    func body(_ id: MessageRowID) throws -> MessageBody?
    func attachments(message: MessageRowID) throws -> [AttachmentItem]

    func counts(account: AccountID) throws -> MailboxCounts

    func drafts(account: AccountID?, states: Set<DraftState>, limit: Int) throws -> [DraftListItem]
    func draft(_ id: DraftID) throws -> DraftListItem?
    func draft(account: AccountID, gmailDraftID: GmailDraftID) throws -> DraftListItem?
    func reviewQueue(account: AccountID?) throws -> [DraftListItem]
    func snippets(account: AccountID?) throws -> [SnippetItem]
    func contactSuggestions(account: AccountID, prefix: String, limit: Int) throws -> [ContactSuggestion]
    func recentThreads(involving email: String, account: AccountID, limit: Int) throws -> [ThreadListItem]

    func syncStatus(account: AccountID) throws -> SyncStatus
    func operations(account: AccountID?, statuses: Set<OperationStatus>, limit: Int) throws -> [OperationItem]
    func operation(_ id: OperationID) throws -> OperationItem?
    func syncLog(account: AccountID, limit: Int) throws -> [SyncLogEntry]

    func superhumanReminderEmails(account: AccountID, limit: Int) throws -> [SuperhumanReminderEmailItem]
}
