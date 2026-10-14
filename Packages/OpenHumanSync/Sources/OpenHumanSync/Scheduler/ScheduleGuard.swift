import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import Synchronization

struct RunnerContext: Sendable {
    let account: AccountID
    let store: MailStore
    let syncer: AccountSyncer
    let api: any GmailAPI
    let clock: any OHClock
    let jitter: Duration
    let emit: @Sendable (EngineEvent) -> Void
    let pokeDrainer: @Sendable () async -> Void
    let isReachable: @Sendable () -> Bool
    let labelsFreshness: LabelsFreshness
}

final class LabelsFreshness: Sendable {
    private let refreshedAt = Mutex<Date?>(nil)
    func isStale(now: Date, maxAge: Duration) -> Bool {
        refreshedAt.withLock { $0.map { now.timeIntervalSince($0) > maxAge.timeInterval } ?? true }
    }
    func mark(_ date: Date) { refreshedAt.withLock { $0 = date } }
}

enum ScheduleJitter {
    static let windowSeconds: UInt64 = 15

    static func delay(for writerID: String) -> Duration {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in writerID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return .seconds(Int64(hash % windowSeconds))
    }
}

struct ScheduleGuard: Sendable {
    let context: RunnerContext
    static let labelsMaxAge: Duration = .seconds(600)
    private let log = Log(.scheduler)

    init(_ context: RunnerContext) { self.context = context }

    func historyCheck(reason: String = "schedule-preflight") async -> Bool {
        guard context.isReachable() else { return false }
        do {
            let now = context.clock.now
            if context.labelsFreshness.isStale(now: now, maxAge: Self.labelsMaxAge) {
                try await context.syncer.refreshLabels()
                context.labelsFreshness.mark(now)
            }
            try await context.syncer.sync(reason: reason)
            return true
        } catch {
            log.notice("account \(context.account.rawValue): preflight sync failed (\(AccountSyncer.code(error)))")
            return false
        }
    }

    enum SnoozeCheck: Equatable {
        case confirmed(labels: [String], messageIDs: [GmailMessageID])
        case stop(String)
    }

    func confirmSnooze(_ ref: ThreadRef,
                       select: @Sendable ([ScheduleLabel]) -> [ScheduleLabel]) async throws -> SnoozeCheck {
        let thread: GmailThread
        do {
            thread = try await context.api.getThread(id: ref.gmailThreadID.rawValue, format: .minimal,
                                                     metadataHeaders: [], priority: .sync)
        } catch GmailError.notFound {
            return .stop("thread gone")
        }
        let rows = try context.store.labels(account: context.account)
        var nameByID: [String: String] = [:]
        for row in rows where nameByID[row.key] == nil { nameByID[row.key] = row.name }
        let local = try context.store.threadDetail(ref.rowID)?.messages ?? []
        let localIDs = Set(local.flatMap { $0.labelIDs.map(\.rawValue) })

        var stamps: [String: ScheduleLabel] = [:]
        var carriers: [String: [String]] = [:]
        for message in thread.messages ?? [] {
            for id in message.labelIds ?? [] {
                guard let name = nameByID[id] else { return .stop("unknown label on thread") }
                guard case let .schedule(label) = ScheduleLabel.parse(name), label.kind == .snoozed else { continue }
                stamps[id] = label
                carriers[id, default: []].append(message.id)
            }
        }
        if stamps.keys.contains(where: { !localIDs.contains($0) }) { return .stop("rescheduled elsewhere") }
        let chosen = Set(select(stamps.values.sorted()))
        guard !chosen.isEmpty else { return .stop("no confirmed stamp") }
        var messageIDs: [GmailMessageID] = []
        var seen = Set<String>()
        for (id, label) in stamps.sorted(by: { $0.value < $1.value }) where chosen.contains(label) {
            for message in carriers[id] ?? [] where seen.insert(message).inserted { messageIDs.append(GmailMessageID(message)) }
        }
        return .confirmed(labels: chosen.sorted().map(\.name), messageIDs: messageIDs)
    }

    enum SendCheck: Equatable { case proceed, stop(String), needsAttention(String) }

    func confirmScheduledSend(_ draft: DraftListItem) async throws -> SendCheck {
        guard let gmailDraftID = draft.gmailDraftID, let sendAt = draft.sendAt else { return .stop("not synced") }
        let remote: GmailDraft
        do {
            remote = try await context.api.getDraft(id: gmailDraftID.rawValue, format: .metadata)
        } catch GmailError.notFound {
            try await context.syncer.refreshDrafts()
            return .stop("consumed elsewhere")
        }
        let header = remote.message?.payload?.headers?.first {
            $0.name.caseInsensitiveCompare(OHGmailLabels.sendAtHeader) == .orderedSame
        }?.value.trimmingCharacters(in: .whitespaces)
        guard header == ScheduleStamp.format(sendAt) else {
            try await context.syncer.refreshDrafts()
            return .stop("schedule changed elsewhere")
        }
        let lastRead = await context.syncer.draftCache[gmailDraftID.rawValue]?.gmailMessageID.rawValue
        guard let current = remote.message?.id, current == lastRead else {
            try await context.syncer.refreshDrafts()
            return .stop("edited elsewhere")
        }
        let stamp = ScheduleLabel(kind: .scheduled, due: sendAt).name
        func stampIDs() throws -> Set<String> {
            Set(try context.store.labels(account: context.account).filter { $0.name == stamp }.map(\.key))
        }
        var known = try stampIDs()
        if known.isEmpty {
            try await context.syncer.refreshLabels()
            known = try stampIDs()
        }
        guard !known.isDisjoint(with: remote.message?.labelIds ?? []) else {
            return .needsAttention("scheduled outside OpenHuman")
        }
        return .proceed
    }
}

extension Duration {
    static func elapsed(from: Date, to: Date) -> Duration {
        .milliseconds(Int64((max(0, to.timeIntervalSince(from)) * 1000).rounded()))
    }
}
