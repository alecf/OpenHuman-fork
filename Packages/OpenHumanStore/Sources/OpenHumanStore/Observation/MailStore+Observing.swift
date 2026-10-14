import Foundation
import GRDB
import OpenHumanCore

extension MailStore: MailObserving {
    public func observeAccounts() -> StoreObservation<[AccountItem]> {
        observe { db in try Row.fetchAll(db, sql: "SELECT * FROM accounts ORDER BY position, account_id").map(Self.accountItem) }
    }

    public func observeLabels(account: AccountID) -> StoreObservation<[LabelItem]> {
        observe { db in try Self.labelItems(account: account.rawValue, in: db) }
    }

    public func observeCounts(account: AccountID) -> StoreObservation<MailboxCounts> {
        observe { db in try Self.mailboxCounts(account: account, in: db) }
    }

    public func observeThreadList(view: MailboxView, limit: Int) -> StoreObservation<ThreadWindow> {
        observe { db in try Self.window(view: view, limit: limit, in: db) }
    }

    public func observeThreadDetail(_ id: ThreadRowID) -> StoreObservation<ThreadDetail?> {
        let dir = attachmentsDirectory
        return observe { db in try Self.detail(id, attachmentsDirectory: dir, in: db) }
    }

    public func observeBody(_ id: MessageRowID) -> StoreObservation<MessageBody?> {
        let dir = attachmentsDirectory
        return observe { db in try Self.bodyItem(id, attachmentsDirectory: dir, in: db) }
    }

    public func observeDrafts(account: AccountID?, states: Set<DraftState>) -> StoreObservation<[DraftListItem]> {
        observe { db in try Self.draftItems(account: account, states: states, limit: Int.max / 2, in: db) }
    }

    public func observeDraft(_ id: DraftID) -> StoreObservation<DraftListItem?> {
        observe { db in try Self.draftItem(id, in: db) }
    }

    public func observeReviewQueue(account: AccountID?) -> StoreObservation<[DraftListItem]> {
        observe { db in try Self.reviewQueueItems(account: account, in: db) }
    }

    public func observeSetting<T: Codable & Sendable & Equatable>(_ key: SettingKey<T>, scope: SettingScope) -> StoreObservation<T> {
        let scopeText = Self.scopeString(scope)
        return observe { db in
            guard let json = try String.fetchOne(db, sql: "SELECT value_json FROM settings WHERE scope = ? AND key = ?",
                                                 arguments: [scopeText, key.name]) else { return key.defaultValue }
            do { return try JSONDecoder().decode(T.self, from: Data(json.utf8)) } catch {
                if key.isSafetyKey { throw StoreError.integrity("setting \(key.name) is unreadable") }
                return key.defaultValue
            }
        }
    }

    public func observeSyncStatus(account: AccountID) -> StoreObservation<SyncStatus> {
        observe { db in
            var lease = try Self.leaseInfo(account: account.rawValue, in: db)
            lease?.heartbeatAt = .distantPast
            return try Self.syncStatus(account: account, lease: lease, in: db)
        }
    }

    public func observeFailedOperations() -> StoreObservation<[OperationItem]> {
        observe { db in try Self.operationItems(account: nil, statuses: [.failed], limit: 1000, in: db) }
    }

    public func observeSplits(account: AccountID) -> StoreObservation<[SplitItem]> {
        observe { db in try Self.splitItems(account: account.rawValue, in: db) }
    }

    public func observeReminders(account: AccountID?) -> StoreObservation<[ReminderSummary]> {
        observe { db in try Self.reminderSummaries(account: account, limit: 1000, in: db) }
    }
}

extension MailStore: SnippetObserving {
    public func observeSnippets(account: AccountID?) -> StoreObservation<[SnippetItem]> {
        observe { db in try Self.snippetItems(account: account, in: db) }
    }
}
