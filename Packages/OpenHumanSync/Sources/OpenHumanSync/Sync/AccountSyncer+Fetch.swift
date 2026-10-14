import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

extension AccountSyncer {
    struct ThreadFetch {
        var counts = Counts()
        var threads: [String: GmailThread] = [:]
        var gone: [String] = []
        var firstError: Error?
    }

    func needingFetch(_ stubs: [GmailThread]) throws -> [String] {
        let pairs = stubs.compactMap { s in s.historyId.flatMap { UInt64($0) }.map { (GmailThreadID(s.id), HistoryID($0)) } }
        let needed = Set(try store.threadsNeedingFetch(account: account, stubs: pairs).map(\.rawValue))
        return stubs.filter { $0.historyId == nil || needed.contains($0.id) }.map(\.id)
    }

    func fetchThreadChunk(_ ids: [String], generation: Int, priority: RequestPriority, sweep: Bool,
                          tombstone: HistoryID) async throws -> ThreadFetch {
        var out = ThreadFetch()
        guard !ids.isEmpty else { return out }
        let results = try await api.getThreads(ids: ids, format: .metadata, metadataHeaders: standardMetadataHeaders,
                                               priority: priority)
        var upserts: [MessageUpsert] = []
        for item in results {
            switch item.result {
            case .success(let thread):
                out.threads[item.id] = thread
                for message in thread.messages ?? [] {
                    do { upserts.append(try GmailMapper.messageUpsert(message, includeBody: false)) }
                    catch { log.notice("account \(account.rawValue): message \(message.id) skipped (\(Self.code(error)))") }
                }
            case .failure(.notFound):
                out.gone.append(item.id)
            case .failure(let error):
                out.firstError = out.firstError ?? error
            }
        }
        let result = try store.upsertMessages(upserts, account: account, generation: generation)
        out.counts.added += result.inserted
        out.counts.changed += result.updated
        if !result.unknownLabelIDs.isEmpty { try await refreshLabels() }
        if sweep {
            for (id, thread) in out.threads {
                let present = Set((thread.messages ?? []).map(\.id))
                let stale = try localMessageIDs(thread: id).filter { !present.contains($0) }
                if !stale.isEmpty {
                    let h = thread.historyId.flatMap { UInt64($0) }.map { HistoryID($0) } ?? tombstone
                    out.counts.deleted += try store.deleteMessages(stale.map { GmailMessageID($0) }, account: account,
                                                                   historyID: h).updated
                }
            }
        }
        if sweep || priority != .interactive {
            for id in out.gone {
                let local = try localMessageIDs(thread: id)
                if !local.isEmpty {
                    out.counts.deleted += try store.deleteMessages(local.map { GmailMessageID($0) }, account: account,
                                                                   historyID: tombstone).updated
                }
            }
        }
        return out
    }

    func fetchMessagesFull(_ ids: [String], generation: Int, tombstone: HistoryID,
                           fetched: inout [GmailMessage]) async throws -> Counts {
        var counts = Counts()
        let results = try await api.getMessages(ids: ids, format: .full, metadataHeaders: [], priority: .sync)
        let horizon = clock.now.addingTimeInterval(-settings.bodyHorizon.timeInterval)
        var upserts: [MessageUpsert] = []
        var stored: [GmailMessage] = []
        var gone: [GmailMessageID] = []
        var firstError: Error?
        for item in results {
            switch item.result {
            case .success(let message):
                let inHorizon = (message.internalDateValue ?? .distantPast) >= horizon
                do {
                    upserts.append(try GmailMapper.messageUpsert(message, includeBody: inHorizon))
                    stored.append(message)
                } catch {
                    log.notice("account \(account.rawValue): message \(message.id) skipped (\(Self.code(error)))")
                }
            case .failure(.notFound):
                gone.append(GmailMessageID(item.id))
            case .failure(let error):
                firstError = firstError ?? error
            }
        }
        counts += try await fetchThreadsFirstSeen(upserts, generation: generation, tombstone: tombstone)
        let result = try store.upsertMessages(upserts, account: account, generation: generation)
        fetched += stored
        counts.added += result.inserted
        counts.changed += result.updated
        if !result.unknownLabelIDs.isEmpty { try await refreshLabels() }
        if !gone.isEmpty {
            counts.deleted += try store.deleteMessages(gone, account: account, historyID: tombstone).updated
        }
        if let firstError { throw firstError }
        return counts
    }

    // Why: a thread with no row may hold older messages the backfill has not stored, and thread actions would miss them
    private func fetchThreadsFirstSeen(_ upserts: [MessageUpsert], generation: Int,
                                       tombstone: HistoryID) async throws -> Counts {
        guard !upserts.isEmpty, !(try store.syncStatus(account: account).backfillComplete) else { return Counts() }
        var checked = Set<GmailThreadID>()
        var ids: [String] = []
        for upsert in upserts where checked.insert(upsert.gmailThreadID).inserted {
            if try store.thread(account: account, gmailThreadID: upsert.gmailThreadID) == nil {
                ids.append(upsert.gmailThreadID.rawValue)
            }
        }
        var counts = Counts()
        let size = max(settings.fetchChunk, 1)
        for start in stride(from: 0, to: ids.count, by: size) {
            let fetched = try await fetchThreadChunk(Array(ids[start..<min(start + size, ids.count)]), generation: generation,
                                                     priority: .sync, sweep: false, tombstone: tombstone)
            counts += fetched.counts
            if let error = fetched.firstError { throw error }
        }
        return counts
    }
}
