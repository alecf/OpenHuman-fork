import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

extension MailEngine {
    @discardableResult
    public func syncNow(_ account: AccountID?, reason: String) async throws -> [SyncReport] {
        try EnginePolicy.checkNetwork(role: configuration.role, what: "syncNow")
        if let account {
            guard let runtime = runtimes[account] else {
                throw EngineError.requiresApp("account \(account.rawValue) is not synced by this process")
            }
            return [try await runtime.syncNow(reason: reason)]
        }
        var reports: [SyncReport] = []
        for (id, runtime) in runtimes.sorted(by: { $0.key < $1.key }) {
            do { reports.append(try await runtime.syncNow(reason: reason)) } catch {
                reports.append(SyncReport(accountID: id, kind: "sync", added: 0, changed: 0, deleted: 0, units: 0,
                                          duration: .zero, error: AccountSyncer.code(error)))
            }
        }
        return reports
    }

    public func ensureViewLoaded(_ view: MailboxView) async throws {
        try EnginePolicy.checkNetwork(role: configuration.role, what: "ensureViewLoaded")
        switch view {
        case let .system(account, mailbox):
            guard let label = Self.gmailLabel(mailbox) else { return }
            try await loadView(account: account, labelID: label)
        case let .label(account, label):
            try await loadView(account: account, labelID: label.rawValue)
        case .split, .splitOther:
            return
        case let .unified(mailbox):
            guard let label = Self.gmailLabel(mailbox) else { return }
            for account in runtimes.keys.sorted() { try await loadView(account: account, labelID: label) }
        }
    }

    public func ensureBodies(thread: ThreadRowID) async throws {
        try EnginePolicy.checkNetwork(role: configuration.role, what: "ensureBodies")
        guard let detail = try store.threadDetail(thread) else { throw StoreError.notFound("thread \(thread.rawValue)") }
        let account = detail.thread.ref.accountID
        let gate = runtimes[account]?.gate
        let clock = configuration.clock
        gate?.beginInteractive()
        defer { gate?.endInteractive(now: clock.now) }
        _ = try await BodyFetcher(account: account, store: store, api: try client(for: account))
            .ensureBodies(thread: thread, priority: .interactive)
    }

    public func ensureBody(message: MessageRowID) async throws {
        try EnginePolicy.checkNetwork(role: configuration.role, what: "ensureBody")
        if try store.body(message) != nil { return }
        guard let key = try store.messageKey(message) else {
            throw StoreError.notFound("message row \(message.rawValue)")
        }
        try await ensureBody(account: key.ref.accountID, gmailMessageID: key.gmailMessageID)
    }

    @discardableResult
    public func ensureBody(account: AccountID, gmailMessageID: GmailMessageID) async throws -> Bool {
        try EnginePolicy.checkNetwork(role: configuration.role, what: "ensureBody")
        let gate = runtimes[account]?.gate
        let clock = configuration.clock
        gate?.beginInteractive()
        defer { gate?.endInteractive(now: clock.now) }
        let fetcher = BodyFetcher(account: account, store: store, api: try client(for: account))
        if let message = try store.message(account: account, gmailMessageID: gmailMessageID),
           let key = try store.messageKey(message.id) {
            let thread = key.ref.rowID
            func stored() throws -> Bool {
                try store.message(account: account, gmailMessageID: gmailMessageID)?.bodyState == .stored
            }
            if let running = threadBodyFetches[thread] {
                _ = try? await running.value
                if try stored() { return true }
            } else if message.isUnread, Self.needsBody(message), let detail = try store.threadDetail(thread),
                      detail.messages.filter({ $0.isUnread && !$0.isDraft && Self.needsBody($0) }).count >= 2 {
                let task = Task { try await fetcher.ensureBodies(thread: thread, priority: .interactive) }
                threadBodyFetches[thread] = task
                defer { threadBodyFetches[thread] = nil }
                _ = try await task.value
                return try stored()
            }
        }
        return try await fetcher.ensureBody(gmailMessageID, priority: .interactive)
    }

    private static func needsBody(_ message: MessageItem) -> Bool {
        message.bodyState == .none || message.bodyState == .metadataOnly
    }

    public func fetchThread(account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadRef? {
        try EnginePolicy.checkNetwork(role: configuration.role, what: "fetchThread")
        if let ref = try store.thread(account: account, gmailThreadID: gmailThreadID) { return ref }
        try await fetchThreads(account: account, ids: [gmailThreadID.rawValue], api: try client(for: account))
        return try store.thread(account: account, gmailThreadID: gmailThreadID)
    }

    public func fetchDraft(account: AccountID, gmailDraftID: GmailDraftID) async throws -> DraftID? {
        try EnginePolicy.checkNetwork(role: configuration.role, what: "fetchDraft")
        if let draft = try store.draft(account: account, gmailDraftID: gmailDraftID) { return draft.id }
        let syncer = try runtimes[account]?.syncer
            ?? AccountSyncer(account: account, store: store, api: client(for: account), clock: configuration.clock)
        try await syncer.refreshDrafts()
        return try store.draft(account: account, gmailDraftID: gmailDraftID)?.id
    }

    public nonisolated func observeConnectivity() -> AsyncStream<[AccountID: AccountConnectivity]> {
        guard configuration.role == .app else {
            let snapshot = connectivitySnapshot()
            return AsyncStream { continuation in
                continuation.yield(snapshot)
                continuation.finish()
            }
        }
        return connectivity.stream()
    }

    public nonisolated func observeSyncProgress() -> AsyncStream<[AccountID: SyncProgress]> {
        progress.stream()
    }

    public nonisolated func syncProgress(_ account: AccountID) -> SyncProgress? {
        progress.current[account]
    }

    public func attachmentFile(_ attachmentID: Int64) async throws -> URL {
        try EnginePolicy.checkNetwork(role: configuration.role, what: "attachmentFile")
        guard let key = try store.attachmentKey(attachmentID) else {
            throw StoreError.notFound("attachment \(attachmentID)")
        }
        return try await attachmentFile(account: key.ref.accountID, message: key.gmailMessageID, attachment: attachmentID)
    }

    public func attachmentFile(account: AccountID, message: GmailMessageID, attachment: Int64) async throws -> URL {
        try EnginePolicy.checkNetwork(role: configuration.role, what: "attachmentFile")
        return try await AttachmentFetcher(account: account, store: store, api: try client(for: account),
                                           storeDirectory: store.location.directory)
            .attachmentFile(message: message, attachment: attachment)
    }

    public func remoteSearch(_ query: String, account: AccountID, maxResults: Int) async throws -> [ThreadRef] {
        try EnginePolicy.checkNetwork(role: configuration.role, what: "remoteSearch")
        return try await RemoteSearch(account: account, store: store, api: try client(for: account))
            .search(gmailQuery: query, maxResults: maxResults)
    }

    func client(for account: AccountID) throws -> any GmailAPI {
        if let runtime = runtimes[account] { return runtime.api }
        guard let gmailFactory else { throw EngineError.requiresApp("no Gmail client in this process") }
        guard let item = try store.accounts().first(where: { $0.id == account }) else {
            throw StoreError.notFound("account \(account.rawValue)")
        }
        return try gmailFactory.client(for: item.email)
    }

    static func gmailLabel(_ mailbox: SystemMailbox) -> String? {
        switch mailbox {
        case .inbox: return "INBOX"
        case .starred: return "STARRED"
        case .important: return "IMPORTANT"
        case .unread: return "UNREAD"
        case .sent: return "SENT"
        case .drafts: return "DRAFT"
        case .trash: return "TRASH"
        case .spam: return "SPAM"
        case .allMail, .snoozed, .scheduled, .reminders, .done, .waiting: return nil
        }
    }

    private func loadView(account: AccountID, labelID: String) async throws {
        let api = try client(for: account)
        let listing = try await api.listThreads(ListQuery(labelIDs: [labelID], maxResults: 100), priority: .interactive)
        let stubs = listing.threads ?? []
        let pairs = stubs.compactMap { stub in
            stub.historyId.flatMap { UInt64($0) }.map { (GmailThreadID(stub.id), HistoryID($0)) }
        }
        let needed = Set(try store.threadsNeedingFetch(account: account, stubs: pairs).map(\.rawValue))
        let ids = stubs.filter { $0.historyId == nil || needed.contains($0.id) }.map(\.id)
        try await fetchThreads(account: account, ids: ids, api: api)
    }

    private func fetchThreads(account: AccountID, ids: [String], api: any GmailAPI) async throws {
        guard !ids.isEmpty else { return }
        let gate = runtimes[account]?.gate
        let clock = configuration.clock
        gate?.beginInteractive()
        defer { gate?.endInteractive(now: clock.now) }
        let generation = try store.syncStatus(account: account).generation
        for start in stride(from: 0, to: ids.count, by: 50) {
            let chunk = Array(ids[start..<min(start + 50, ids.count)])
            let results = try await api.getThreads(ids: chunk, format: .metadata,
                                                   metadataHeaders: standardMetadataHeaders, priority: .interactive)
            var upserts: [MessageUpsert] = []
            var firstError: GmailError?
            for item in results {
                switch item.result {
                case .success(let thread):
                    for message in thread.messages ?? [] {
                        do { upserts.append(try GmailMapper.messageUpsert(message, includeBody: false)) } catch {
                            log.notice("account \(account.rawValue): message \(message.id) skipped (mapping)")
                        }
                    }
                case .failure(.notFound):
                    continue
                case .failure(let error):
                    firstError = firstError ?? error
                }
            }
            if !upserts.isEmpty {
                let result = try store.upsertMessages(upserts, account: account, generation: generation)
                if !result.unknownLabelIDs.isEmpty {
                    let labels = try await api.listLabels()
                    try store.upsertLabels(labels.map(GmailMapper.labelUpsert), account: account, removeMissing: true)
                }
            }
            if let firstError, upserts.isEmpty { throw firstError }
        }
    }

    nonisolated func connectivitySnapshot() -> [AccountID: AccountConnectivity] {
        var out: [AccountID: AccountConnectivity] = [:]
        for account in (try? store.accounts()) ?? [] where Self.isSyncable(account) {
            let last = (try? store.syncStatus(account: account.id))?.lastSuccessAt
            if account.status == .needsReauth {
                out[account.id] = .needsReauth
            } else if let lease = OwnershipManager.liveOwner(account: account.id, store: store) {
                out[account.id] = .ownedElsewhere(kind: lease.kind, lastSyncAt: last)
            } else {
                out[account.id] = .offline(since: last ?? configuration.clock.now)
            }
        }
        return out
    }
}
