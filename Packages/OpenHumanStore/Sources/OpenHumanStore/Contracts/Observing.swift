import Foundation
import OpenHumanCore

public protocol MailObserving: Sendable {
    func observeAccounts() -> StoreObservation<[AccountItem]>
    func observeLabels(account: AccountID) -> StoreObservation<[LabelItem]>
    func observeCounts(account: AccountID) -> StoreObservation<MailboxCounts>
    func observeThreadList(view: MailboxView, limit: Int) -> StoreObservation<ThreadWindow>
    func observeThreadDetail(_ id: ThreadRowID) -> StoreObservation<ThreadDetail?>
    func observeBody(_ id: MessageRowID) -> StoreObservation<MessageBody?>
    func observeDrafts(account: AccountID?, states: Set<DraftState>) -> StoreObservation<[DraftListItem]>
    func observeDraft(_ id: DraftID) -> StoreObservation<DraftListItem?>
    func observeReviewQueue(account: AccountID?) -> StoreObservation<[DraftListItem]>
    func observeSetting<T: Codable & Sendable & Equatable>(_ key: SettingKey<T>, scope: SettingScope) -> StoreObservation<T>
    func observeSyncStatus(account: AccountID) -> StoreObservation<SyncStatus>
    func observeFailedOperations() -> StoreObservation<[OperationItem]>
    func observeSplits(account: AccountID) -> StoreObservation<[SplitItem]>
    func observeReminders(account: AccountID?) -> StoreObservation<[ReminderSummary]>
}

public struct ThreadWindow: Equatable, Sendable {
    public var items: [ThreadListItem]
    public var hasMore: Bool
    public var totalCount: Int

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        items: [ThreadListItem],
        hasMore: Bool,
        totalCount: Int
    ) {
        self.items = items
        self.hasMore = hasMore
        self.totalCount = totalCount
    }
    // end generated-init
}
