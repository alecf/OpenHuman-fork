import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME
import OpenHumanStore

public enum EngineRole: Sendable {
    case app
    case localClient
    case readOnly
    case cliOneShot
    case cliDaemon
}

public struct EngineConfiguration: Sendable {
    public var role: EngineRole
    public var appVersion: String
    public var gmail: GmailClientConfig
    public var pollInterval: Duration = .seconds(60)
    public var clock: any OHClock
    public var schedulers: Set<ScheduleKind> = Set(ScheduleKind.allCases)
    public var safeMode: SafeMode = .normal

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        role: EngineRole,
        appVersion: String,
        gmail: GmailClientConfig,
        pollInterval: Duration = .seconds(60),
        clock: any OHClock,
        schedulers: Set<ScheduleKind> = Set(ScheduleKind.allCases),
        safeMode: SafeMode = .normal
    ) {
        self.role = role
        self.appVersion = appVersion
        self.gmail = gmail
        self.pollInterval = pollInterval
        self.clock = clock
        self.schedulers = schedulers
        self.safeMode = safeMode
    }
    // end generated-init
}

public protocol SystemEventsSource: Sendable {
    var events: AsyncStream<SystemEvent> { get }
}
public enum SystemEvent: Sendable { case didWake, didBecomeActive, didResignActive, networkReachable(Bool), willTerminate }

public enum SendAuthorization: Sendable {
    case userConfirmed
    case scheduled
}

public enum EngineError: Error, Equatable, Sendable {
    case requiresApp(String)
    case sendNotAllowed
    case oauthClientMissing
    case blockedBySafeMode(String)
}

public enum EngineEvent: Sendable {
    case accountNeedsReauth(AccountID)
    case operationFailed(OperationItem)
    case sent(DraftID, GmailMessageID?)
    case sendFailed(DraftID, String)
    case sendInterrupted(DraftID)
    case scheduledSendNeedsConfirmation(DraftID)
    case scheduledSendCancelledByReply(DraftID)
    case snoozeWoke(ThreadRef, overdueBy: Duration)
    case reminderFired(ThreadRef, overdueBy: Duration)
    case schedulerDegraded(ScheduleKind, String)
    case scheduleLabelBudget(AccountID, count: Int)
    case syncFailed(AccountID, String)
    case initialSyncProgress(AccountID, phase: SyncPhase, oldest: Date?)
    case ownershipChanged(AccountID, isOwner: Bool)
}

public struct NewDraft: Sendable, Hashable {
    public var id: DraftID
    public var version: Int
    public var skeleton: ReplySkeleton?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: DraftID,
        version: Int,
        skeleton: ReplySkeleton? = nil
    ) {
        self.id = id
        self.version = version
        self.skeleton = skeleton
    }
    // end generated-init
}

public enum AccountConnectivity: Hashable, Sendable {
    case online(syncing: Bool, lastSyncAt: Date?)
    case offline(since: Date)
    case rateLimited(until: Date)
    case needsReauth
    case ownedElsewhere(kind: String, lastSyncAt: Date?)
}

public struct SyncReport: Sendable {
    public var accountID: AccountID; public var kind: String; public var added: Int
    public var changed: Int; public var deleted: Int; public var units: Int; public var duration: Duration
    public var error: String?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        accountID: AccountID,
        kind: String,
        added: Int,
        changed: Int,
        deleted: Int,
        units: Int,
        duration: Duration,
        error: String? = nil
    ) {
        self.accountID = accountID
        self.kind = kind
        self.added = added
        self.changed = changed
        self.deleted = deleted
        self.units = units
        self.duration = duration
        self.error = error
    }
    // end generated-init
}

protocol ScheduleRunner: Sendable {
    var kind: ScheduleKind { get }
    func nextDue(account: AccountID, now: Date) async throws -> Date?
    func reconcile(account: AccountID, now: Date) async throws
}
