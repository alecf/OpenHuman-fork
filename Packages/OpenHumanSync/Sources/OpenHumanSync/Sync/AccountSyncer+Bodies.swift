import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

extension AccountSyncer {
    public func bodySettingsChanged() {
        guard backfillTask == nil, backfillFinished else { return }
        backfillFinished = false
        startBackfill()
    }

    func backfillBodies(generation: Int) async throws {
        let horizon = clock.now.addingTimeInterval(-settings.bodyHorizon.timeInterval)
        let recent = try await bodyPass(newerThan: horizon, deep: false, generation: generation)
        if !recent.hadStuck { try store.updateSyncState(account: account) { $0.bodyBackfillComplete = true } }
        guard bodyPolicy().enabled else {
            broadcaster.update { $0.hold = nil }
            return
        }
        _ = try await bodyPass(newerThan: .distantPast, deep: true, generation: generation)
    }

    private func bodyPass(newerThan cutoff: Date, deep: Bool,
                          generation: Int) async throws -> (fetched: Int, hadStuck: Bool) {
        let started = clock.now
        let (units0, calls0) = (pacer.units, pacer.calls)
        let tombstone = try store.syncStatus(account: account).historyID ?? HistoryID(0)
        var stuck = Set<GmailMessageID>()
        var counts = Counts()
        var fetched = 0
        var tally = deep ? try countBodies() : BodyCounts()
        var stored = tally.stored
        if deep {
            broadcaster.update { $0.stage = .searchBodies }
            refreshBodyProgress(tally)
        } else {
            broadcaster.update { $0.stage = .bodies }
        }
        passes: while true {
            try await yieldToRuns(generation: generation)
            let wanted = try store.messagesNeedingBodies(account: account, newerThan: cutoff, limit: 100 + stuck.count)
                .filter { !stuck.contains($0) }
            if wanted.isEmpty { break }
            let size = max(settings.bodyChunk, 1)
            for start in stride(from: 0, to: min(wanted.count, 100), by: size) {
                try await waitForGate(generation: generation)
                var room = size
                if deep {
                    let policy = bodyPolicy()
                    guard policy.enabled else { break passes }
                    if let cap = policy.maxMessages { room = min(room, cap - stored) }
                    if room <= 0 { break passes }
                }
                let chunk = Array(wanted[start..<min(start + room, wanted.count, 100)])
                try await yieldToRuns(generation: generation)
                try await pace(BackfillPacer.cost(.getMessage, count: chunk.count), calls: chunk.count)
                let signpost = SyncSignposts.begin("bodies-page")
                let results = try await api.getMessages(ids: chunk.map(\.rawValue), format: .full, metadataHeaders: [],
                                                        priority: .backfill)
                SyncSignposts.end(signpost)
                let saved = try BodyFetcher.store(results, account: account, store: store, log: log)
                fetched += saved
                stored += saved
                var gone: [GmailMessageID] = []
                var pauseError: Error?
                for item in results {
                    guard case .failure(let error) = item.result else { continue }
                    if case .notFound = error {
                        gone.append(GmailMessageID(item.id))
                    } else {
                        stuck.insert(GmailMessageID(item.id))
                        if rateLimitPause(error) != nil { pauseError = pauseError ?? error }
                    }
                }
                if !gone.isEmpty {
                    counts.deleted += try store.deleteMessages(gone, account: account, historyID: tombstone).updated
                }
                if deep {
                    broadcaster.update { $0.bodiesFetched += saved }
                    tally.stored = stored
                    tally.pending = max(tally.pending - saved - gone.count, 0)
                    refreshBodyProgress(tally)
                } else {
                    broadcaster.update { $0.bodiesFetched += saved }
                }
                if let pauseError { throw pauseError }
                noteBackfillProgress()
            }
        }
        counts.changed = fetched
        if pacer.calls > calls0 {
            appendLog("bodies", started, clock.now, outcome: "ok", units: pacer.units - units0,
                      requests: pacer.calls - calls0, counts, errorCode: nil, detail: deep ? "search" : nil)
        }
        return (fetched, !stuck.isEmpty)
    }

    private func refreshBodyProgress(_ counts: BodyCounts) {
        var total = counts.stored + counts.pending
        if let cap = bodyPolicy().maxMessages { total = min(total, cap) }
        broadcaster.update {
            $0.bodiesDone = counts.stored
            $0.bodiesTotal = total
        }
    }

    private func countBodies() throws -> BodyCounts {
        bodyCountQueries += 1
        return try store.bodyCounts(account: account)
    }

    func waitForGate(generation: Int) async throws {
        guard let gate else { return }
        while let hold = gate.hold(now: clock.now) {
            if broadcaster.current.hold != hold { broadcaster.update { $0.hold = hold } }
            try await clock.sleep(for: BackfillGate.recheck)
            try await yieldToRuns(generation: generation)
        }
        if broadcaster.current.hold != nil { broadcaster.update { $0.hold = nil } }
    }
}
