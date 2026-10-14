import Foundation
import OpenHumanCore

public struct DueItems: Sendable {
    public var snoozesToWake: [(ThreadRef, SnoozeInfo)]
    public var snoozesWokenByMail: [(ThreadRef, SnoozeInfo)]
    public var snoozesToNormalize: [(ThreadRef, SnoozeInfo)]
    public var remindersDue: [(ThreadRef, ReminderInfo)]
    public var scheduledSendsDue: [DraftListItem]
    public var overdueUndoSends: [OperationItem]

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        snoozesToWake: [(ThreadRef, SnoozeInfo)],
        snoozesWokenByMail: [(ThreadRef, SnoozeInfo)],
        snoozesToNormalize: [(ThreadRef, SnoozeInfo)],
        remindersDue: [(ThreadRef, ReminderInfo)],
        scheduledSendsDue: [DraftListItem],
        overdueUndoSends: [OperationItem]
    ) {
        self.snoozesToWake = snoozesToWake
        self.snoozesWokenByMail = snoozesWokenByMail
        self.snoozesToNormalize = snoozesToNormalize
        self.remindersDue = remindersDue
        self.scheduledSendsDue = scheduledSendsDue
        self.overdueUndoSends = overdueUndoSends
    }
    // end generated-init
}

public enum ScheduleKind: String, Codable, Sendable, CaseIterable { case snooze, sendLater = "send_later", reminder }

public struct ReminderSummary: Hashable, Sendable {
    public var ref: ThreadRef
    public var reminder: ReminderInfo
    public var subject: String

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        ref: ThreadRef,
        reminder: ReminderInfo,
        subject: String
    ) {
        self.ref = ref
        self.reminder = reminder
        self.subject = subject
    }
    // end generated-init
}

public protocol ReminderStoring: Sendable {
    func fireReminder(_ id: String, now: Date, satisfied: Bool) throws -> ActionReceipt?
    func hasReplySince(_ thread: ThreadRef, anchor: GmailMessageID?) throws -> Bool
    func activeReminders(account: AccountID?, limit: Int) throws -> [ReminderSummary]
}

public protocol SchedulingStoring: ReminderStoring {
    func dueItems(account: AccountID, now: Date) throws -> DueItems
    func nextDueTime(account: AccountID, kinds: Set<ScheduleKind>) throws -> Date?

    func wakeSnooze(_ thread: ThreadRef, confirmedLabels: [String], messageIDs: [GmailMessageID], now: Date) throws -> ActionReceipt
    func clearSnooze(_ thread: ThreadRef, confirmedLabels: [String], messageIDs: [GmailMessageID]) throws -> ActionReceipt
    func normalizeSnooze(_ thread: ThreadRef, keep: String, remove: [String], messageIDs: [GmailMessageID]) throws -> ActionReceipt

    func markScheduledSendNeedsAttention(_ id: DraftID, reason: String) throws
}

public protocol LeaseStoring: Sendable {
    func acquireLease(account: AccountID, ownerID: String, kind: String, pid: Int32, host: String, now: Date, ttl: Duration) throws -> LeaseInfo?
    func renewLease(account: AccountID, ownerID: String, now: Date, ttl: Duration) throws -> Bool
    func releaseLease(account: AccountID, ownerID: String) throws
    func requestTakeover(account: AccountID, requesterID: String, now: Date) throws
    func lease(account: AccountID) throws -> LeaseInfo?
}
