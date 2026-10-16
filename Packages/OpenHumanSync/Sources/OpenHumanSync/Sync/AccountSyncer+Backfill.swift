import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

public enum BackfillOutcome: Sendable, Equatable {
    case complete
    case notReady
    case stopped(String)
    case cancelled
}

struct BackfillRestart: Error {}

extension AccountSyncer {
    static let walkTop = Date.distantFuture

    public var isBackfillRunning: Bool { backfillTask != nil }

    public var isBackfillPaused: Bool { backfillPaused }

    public func startBackfill() {
        guard backfillTask == nil, !backfillFinished, !backfillPaused else { return }
        spawnBackfill()
    }

    public func pauseBackfill() {
        backfillPaused = true
        cancelBackfill()
    }

    public func resumeBackfill() {
        backfillPaused = false
    }

    @discardableResult
    public func runBackfill() async -> BackfillOutcome {
        if let task = backfillTask { return await task.value }
        if backfillFinished { return .complete }
        return await spawnBackfill().value
    }

    public func stopBackfill() {
        cancelBackfill()
    }

    func cancelBackfill() {
        backfillTask?.cancel()
        backfillTask = nil
        broadcaster.update {
            $0.isRunning = false
            $0.pausedUntil = nil
        }
    }

    @discardableResult
    private func spawnBackfill() -> Task<BackfillOutcome, Never> {
        backfillTaskID &+= 1
        let id = backfillTaskID
        let task = Task { await self.backfillLoop(id: id) }
        backfillTask = task
        return task
    }

    private func backfillLoop(id: UInt64) async -> BackfillOutcome {
        broadcaster.update { $0.isRunning = true }
        let outcome = await backfillAttempts()
        guard backfillTaskID == id else { return outcome }
        backfillTask = nil
        if outcome == .complete { backfillFinished = true }
        refreshInboxProgress()
        broadcaster.update {
            $0.isRunning = false
            $0.pausedUntil = nil
            if outcome == .complete { $0.stage = .complete } else if $0.stage != .complete { $0.stage = .idle }
        }
        log.info("account \(account.rawValue): backfill ended (\(outcome))")
        return outcome
    }

    private func backfillAttempts() async -> BackfillOutcome {
        while true {
            if Task.isCancelled { return .cancelled }
            do {
                return try await backfillPass()
            } catch is BackfillRestart {
                continue
            } catch {
                if Task.isCancelled { return .cancelled }
                let code = Self.code(error)
                if code == "cancelled" { return .cancelled }
                if var wait = rateLimitPause(error) {
                    rateLimitStreak += 1
                    if case GmailError.rateLimited(nil) = error { wait = wait * (1 << min(rateLimitStreak - 1, 4)) }
                    if case GmailError.quotaBudgetExhausted = error { wait = wait * (1 << min(rateLimitStreak - 1, 4)) }
                    let until = clock.now.addingTimeInterval(wait.timeInterval)
                    broadcaster.update { $0.pausedUntil = until }
                    log.notice("account \(account.rawValue): backfill paused \(Int(wait.timeInterval)) s (\(code))")
                    appendLog("backfill", clock.now, clock.now, outcome: "error", units: 0, requests: 0, Counts(),
                              errorCode: code, detail: "paused")
                    do { try await clock.sleep(for: wait) } catch { return .cancelled }
                    broadcaster.update { $0.pausedUntil = nil }
                    continue
                }
                log.notice("account \(account.rawValue): backfill stopped (\(code))")
                appendLog("backfill", clock.now, clock.now, outcome: "error", units: 0, requests: 0, Counts(),
                          errorCode: code, detail: "stopped")
                return .stopped(code)
            }
        }
    }

    func noteBackfillProgress() { rateLimitStreak = 0 }

    func rateLimitPause(_ error: Error) -> Duration? {
        switch error {
        case GmailError.rateLimited(let retryAfter): return retryAfter ?? settings.rateLimitPause
        case GmailError.quotaBudgetExhausted: return settings.rateLimitPause
        case GmailError.dailyLimitExceeded: return .seconds(3_600)
        default: return nil
        }
    }

    private func backfillPass() async throws -> BackfillOutcome {
        try await yieldToRuns(generation: try store.syncStatus(account: account).generation)
        let status = try store.syncStatus(account: account)
        guard status.historyID != nil, [.inboxReady, .backfilling, .incremental].contains(status.phase) else {
            return .notReady
        }
        let generation = status.generation
        if !status.backfillComplete {
            if status.phase != .backfilling {
                try await backfillHotViews(generation: generation)
            }
            try await backfillAllMail(generation: generation, resync: generation > 1)
        }
        try await backfillBodies(generation: generation)
        return .complete
    }

    func pace(_ cost: Int, calls: Int = 1) async throws {
        let wait = pacer.charge(cost, calls: calls, now: clock.now)
        if wait > .zero { try await clock.sleep(for: wait) }
    }

    func yieldToRuns(generation: Int) async throws {
        try Task.checkCancellation()
        while let run = current {
            backfillWaitsForRun = true
            _ = try? await run.value
            backfillWaitsForRun = false
            try Task.checkCancellation()
        }
        guard try store.syncStatus(account: account).generation == generation else { throw BackfillRestart() }
    }

    private func fetchPaced(_ ids: [String], generation: Int, priority: RequestPriority, sweep: Bool,
                            tombstone: HistoryID) async throws -> Counts {
        var counts = Counts()
        let size = max(settings.fetchChunk, 1)
        for start in stride(from: 0, to: ids.count, by: size) {
            let chunk = Array(ids[start..<min(start + size, ids.count)])
            try await yieldToRuns(generation: generation)
            try await pace(BackfillPacer.cost(.getThread, count: chunk.count), calls: chunk.count)
            let signpost = SyncSignposts.begin("backfill-page")
            let fetched = try await fetchThreadChunk(chunk, generation: generation, priority: priority, sweep: sweep,
                                                     tombstone: tombstone)
            SyncSignposts.end(signpost)
            if fetched.firstError == nil { noteBackfillProgress() }
            counts += fetched.counts
            refreshInboxProgress()
            if let error = fetched.firstError { throw error }
        }
        return counts
    }

    private func backfillHotViews(generation: Int) async throws {
        let started = clock.now
        let (units0, calls0) = (pacer.units, pacer.calls)
        let tombstone = try store.syncStatus(account: account).historyID ?? HistoryID(0)
        broadcaster.update { $0.stage = .inbox }
        try await pace(BackfillPacer.cost(.getLabel))
        let inboxLabel = try await api.getLabel(id: "INBOX")
        broadcaster.update { $0.inboxTotal = inboxLabel.threadsTotal }
        refreshInboxProgress()

        var counts = Counts()
        var token: String?
        var listed = Set<String>()
        repeat {
            try await yieldToRuns(generation: generation)
            try await pace(BackfillPacer.cost(.listThreads))
            let page = try await api.listThreads(ListQuery(labelIDs: ["INBOX"], pageToken: token,
                                                           maxResults: settings.inboxPageSize), priority: .sync)
            let stubs = page.threads ?? []
            listed.formUnion(stubs.map(\.id))
            counts += try await fetchPaced(try needingFetch(stubs), generation: generation, priority: .sync,
                                           sweep: generation > 1, tombstone: tombstone)
            token = page.nextPageToken
        } while token != nil && listed.count < settings.inboxBackfillLimit
        if generation > 1 && token == nil {
            let missing = try missingLocalInboxThreads(listed: listed, newerThan: .distantPast)
            counts += try await fetchPaced(missing, generation: generation, priority: .sync, sweep: true,
                                           tombstone: tombstone)
        }
        try await pace(BackfillPacer.cost(.getLabel))
        if let total = try? await api.getLabel(id: "INBOX").threadsTotal { broadcaster.update { $0.inboxTotal = total } }
        appendLog("backfill", started, clock.now, outcome: "ok", units: pacer.units - units0,
                  requests: pacer.calls - calls0, counts, errorCode: nil, detail: "inbox")

        broadcaster.update { $0.stage = .drafts }
        try await yieldToRuns(generation: generation)
        try await pace(BackfillPacer.cost(.listDrafts))
        try await refreshDrafts()

        broadcaster.update { $0.stage = .recentViews }
        for label in settings.recentViewLabels {
            try await yieldToRuns(generation: generation)
            try await pace(BackfillPacer.cost(.listThreads))
            let page = try await api.listThreads(ListQuery(labelIDs: [label], maxResults: settings.recentViewThreads),
                                                 priority: .sync)
            _ = try await fetchPaced(try needingFetch(page.threads ?? []), generation: generation, priority: .sync,
                                     sweep: false, tombstone: tombstone)
        }
        try store.updateSyncState(account: account) {
            $0.phase = .backfilling
            $0.backfillOldestAt = Self.walkTop
        }
    }

    func missingLocalInboxThreads(listed: Set<String>, newerThan cutoff: Date) throws -> [String] {
        var missing: [String] = []
        var cursor: ThreadCursor?
        repeat {
            let page = try store.threadPage(view: .system(account, .inbox), after: cursor, limit: 200)
            for item in page.items {
                if item.lastMessageAt < cutoff { return missing }
                if !listed.contains(item.ref.gmailThreadID.rawValue) { missing.append(item.ref.gmailThreadID.rawValue) }
                if missing.count >= settings.resyncReconcileLimit { return missing }
            }
            cursor = page.nextCursor
        } while cursor != nil
        return missing
    }

    private func backfillAllMail(generation: Int, resync: Bool) async throws {
        let started = clock.now
        let (units0, calls0) = (pacer.units, pacer.calls)
        broadcaster.update { $0.stage = .allMail }
        let status = try store.syncStatus(account: account)
        let tombstone = status.historyID ?? HistoryID(0)
        var cursor: Date? = status.backfillOldest.flatMap { $0 >= Self.walkTop ? nil : $0 }
        broadcaster.update { $0.oldestSynced = cursor }
        try await pace(BackfillPacer.cost(.getProfile))
        let profile = try await api.getProfile(priority: .backfill)
        broadcaster.update { $0.mailTotal = profile.threadsTotal }
        refreshInboxProgress()
        let horizonStart = settings.metadataHorizon.map { clock.now.addingTimeInterval(-$0.timeInterval) }
        var counts = Counts()
        var fetchedThreads = Set<String>()
        var lastQuery: String?
        while true {
            if let horizonStart, let cursor, cursor <= horizonStart { break }
            try await yieldToRuns(generation: generation)
            var query = cursor.map { Self.beforeQuery($0, inclusive: true) }
            if let q = query, q == lastQuery {
                query = cursor.map { Self.beforeQuery($0, inclusive: false) }
            }
            lastQuery = query
            try await pace(BackfillPacer.cost(.listMessages))
            let page = try await api.listMessages(ListQuery(q: query, maxResults: settings.mailPageSize,
                                                            includeSpamTrash: false), priority: .backfill)
            let stubs = page.messages ?? []
            if stubs.isEmpty { break }

            let known: Set<GmailMessageID> = resync
                ? [] : try store.knownMessageIDs(account: account, among: stubs.map { GmailMessageID($0.id) })
            var targets: [String] = []
            var queued = Set<String>()
            for stub in stubs where !known.contains(GmailMessageID(stub.id)) {
                guard let thread = stub.threadId, !fetchedThreads.contains(thread),
                      queued.insert(thread).inserted else { continue }
                targets.append(thread)
            }
            var dates: [String: Date] = [:]
            let pageIDs = Set(stubs.map(\.id))
            let size = max(settings.fetchChunk, 1)
            for start in stride(from: 0, to: targets.count, by: size) {
                let chunk = Array(targets[start..<min(start + size, targets.count)])
                try await yieldToRuns(generation: generation)
                try await pace(BackfillPacer.cost(.getThread, count: chunk.count), calls: chunk.count)
                let signpost = SyncSignposts.begin("backfill-page")
                let fetched = try await fetchThreadChunk(chunk, generation: generation, priority: .backfill,
                                                         sweep: resync, tombstone: tombstone)
                SyncSignposts.end(signpost)
                if fetched.firstError == nil { noteBackfillProgress() }
                counts += fetched.counts
                if resync {
                    fetchedThreads.formUnion(fetched.threads.keys)
                    fetchedThreads.formUnion(fetched.gone)
                }
                for thread in fetched.threads.values {
                    for m in thread.messages ?? [] where pageIDs.contains(m.id) { dates[m.id] = m.internalDateValue }
                }
                refreshInboxProgress()
                if let error = fetched.firstError { throw error }
            }

            for stub in stubs.suffix(20) where dates[stub.id] == nil {
                dates[stub.id] = try store.message(account: account, gmailMessageID: GmailMessageID(stub.id))?.date
            }
            if dates.isEmpty {
                for stub in stubs where dates[stub.id] == nil {
                    dates[stub.id] = try store.message(account: account, gmailMessageID: GmailMessageID(stub.id))?.date
                }
            }
            guard let oldest = dates.values.min() else {
                throw GmailError.decoding("backfill page without dates")
            }
            let next = min(oldest, cursor ?? oldest)
            cursor = next
            try store.updateSyncState(account: account) { $0.backfillOldestAt = next }
            broadcaster.update { $0.oldestSynced = next }
            if page.nextPageToken == nil { break }
        }

        try await yieldToRuns(generation: generation)
        if resync {
            let swept = try store.sweepGeneration(account: account, olderThan: generation, newerThan: horizonStart)
            counts.deleted += swept
            log.notice("account \(account.rawValue): resync sweep removed \(swept) message(s)")
        }
        try store.pruneTombstones(account: account, olderThan: clock.now)
        try store.updateSyncState(account: account) {
            $0.backfillComplete = true
            $0.phase = .incremental
        }
        refreshInboxProgress()
        appendLog("backfill", started, clock.now, outcome: "ok", units: pacer.units - units0,
                  requests: pacer.calls - calls0, counts, errorCode: nil, detail: resync ? "all_mail_resync" : "all_mail")
    }

    static func beforeQuery(_ date: Date, inclusive: Bool) -> String {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        return "before:\(inclusive ? seconds + 1 : seconds)"
    }
}
