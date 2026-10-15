import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

public actor MailEngine {
    public nonisolated let store: MailStore
    public nonisolated let events: AsyncStream<EngineEvent>

    nonisolated let configuration: EngineConfiguration
    nonisolated let eventSink: AsyncStream<EngineEvent>.Continuation
    nonisolated let connectivity = ConnectivityHub()
    nonisolated let progress = ProgressHub()
    nonisolated let reachability = Reachability()
    let gmailFactory: GmailClientFactory?
    let tokenStore: TokenStore?
    var oauthClient: OAuthClientConfig?
    let systemEvents: SystemEventsSource?
    let metrics: @Sendable (String) -> SyncMetricsCollector?
    let log = Log(.sync)

    var runtimes: [AccountID: AccountRuntime] = [:]
    var ownership: OwnershipManager?
    var started = false
    var isActive = true
    static let maintenanceEvery: TimeInterval = 600
    var lastMaintenanceAt: Date?
    var threadBodyFetches: [ThreadRowID: Task<Int, Error>] = [:]
    var background: [Task<Void, Never>] = []
    var draftDebouncer: DraftSaveDebouncer?

    var jitterOverride: Duration?
    var runnerOverride: (@Sendable (ScheduleKind, RunnerContext) -> (any ScheduleRunner)?)?

    public init(store: MailStore, gmailFactory: GmailClientFactory?, tokenStore: TokenStore?,
                oauthClient: OAuthClientConfig?, configuration: EngineConfiguration,
                systemEvents: SystemEventsSource?,
                metrics: @escaping @Sendable (String) -> SyncMetricsCollector? = { _ in nil }) {
        self.store = store
        self.gmailFactory = gmailFactory
        self.tokenStore = tokenStore
        self.oauthClient = oauthClient
        self.configuration = configuration
        self.systemEvents = systemEvents
        self.metrics = metrics
        (events, eventSink) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    public func start() async {
        guard configuration.role == .app, !started else { return }
        started = true
        let identity = ProcessIdentity(writerID: store.writerID, pid: ProcessInfo.processInfo.processIdentifier,
                                       host: ProcessIdentity.localHostName)
        let ownership = OwnershipManager(store: store, identity: identity, kind: "app", clock: configuration.clock)
        self.ownership = ownership
        let accounts: [AccountItem]
        do { accounts = try store.accounts() } catch {
            log.error("start: cannot read accounts (\(AccountSyncer.code(error)))")
            accounts = []
        }
        for account in accounts where Self.isSyncable(account) { await startAccount(account) }
        await ownership.startHeartbeat(onChange: { [weak self] account, isOwner in
            await self?.ownershipChanged(account, isOwner: isOwner)
        }, afterTick: { [weak self] in
            await self?.requeueLeftovers()
            await self?.runMaintenanceIfDue()
        })
        startBackgroundTasks()
    }

    public func stop() async {
        await draftDebouncer?.flushAll()
        for task in background { task.cancel() }
        background = []
        for runtime in runtimes.values { await runtime.stop() }
        runtimes = [:]
        await ownership?.stopHeartbeat()
        await ownership?.releaseAll()
        ownership = nil
        started = false
    }

    public func flushPendingSends(deadline: Duration) async {
        guard configuration.role == .app else { return }
        await draftDebouncer?.flushAll()
        let flushStart = configuration.clock.now
        var waiting: [OperationID] = []
        for (account, runtime) in runtimes where runtime.writable {
            let pending = (try? store.operations(account: account, statuses: [.pending], limit: 500)) ?? []
            for op in pending where op.kind == .sendDraft {
                guard case let .sendDraft(draftID) = op.payload else { continue }
                let receipt = SendReceipt(draftID: draftID, upsertOperationID: op.dependsOn, sendOperationID: op.id,
                                          sendAfter: op.notBefore)
                if (try? store.sendNow(receipt)) == true { waiting.append(op.id) }
            }
            await runtime.pokeDrainer()
        }
        guard !waiting.isEmpty else { return }
        log.notice("quit: flushing \(waiting.count) send(s)")
        let end = ContinuousClock.now.advanced(by: deadline)
        while ContinuousClock.now < end, !Task.isCancelled {
            let committed = waiting.allSatisfy { id in
                guard let op = try? store.operation(id) else { return true }
                return op.status != .pending || op.nextRetryAt > flushStart
            }
            if committed { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        log.notice("quit: flush deadline reached")
    }

    static func isSyncable(_ account: AccountItem) -> Bool {
        account.status == .active || account.status == .needsReauth
    }

    func startAccount(_ account: AccountItem) async {
        guard runtimes[account.id] == nil, let ownership else { return }
        guard await ownership.acquire(account.id) else {
            markOwnedElsewhere(account.id)
            eventSink.yield(.ownershipChanged(account.id, isOwner: false))
            return
        }
        eventSink.yield(.ownershipChanged(account.id, isOwner: true))
        await launchRuntime(account)
    }

    func launchRuntime(_ account: AccountItem) async {
        guard runtimes[account.id] == nil else { return }
        let writable = EnginePolicy.runsDrainer(account: account)
        if writable {
            let now = configuration.clock.now
            do {
                let requeued = try store.requeueStaleInFlight(account: account.id, claimedBefore: now)
                if requeued > 0 { log.notice("account \(account.id.rawValue): requeued \(requeued) interrupted op(s)") }
                try UndoSendRunner.reconcileAtLaunch(account: account.id, store: store, now: now,
                                                     emit: { [eventSink] in eventSink.yield($0) })
            } catch {
                log.error("account \(account.id.rawValue): launch reconcile failed (\(AccountSyncer.code(error)))")
            }
        }
        guard let gmailFactory else {
            log.notice("account \(account.id.rawValue): no Gmail client factory, local only")
            return
        }
        let api: any GmailAPI
        do { api = try gmailFactory.client(for: account.email) } catch {
            log.notice("account \(account.id.rawValue): no Gmail client (\(AccountSyncer.code(error)))")
            let now = configuration.clock.now
            connectivity.set(account.id, ConnectivityHub.afterFailure(error, now: now, previous: nil, lastSyncAt: nil))
            if case GmailError.reauthRequired = error {
                try? store.setAccountStatus(account.id, .needsReauth)
                eventSink.yield(.accountNeedsReauth(account.id))
            }
            return
        }
        let kinds = EnginePolicy.schedulerKinds(configured: configuration.schedulers, account: account)
        let runtime = AccountRuntime(account: account, api: api, writable: writable, schedulerKinds: kinds,
                                     env: runtimeEnvironment())
        runtimes[account.id] = runtime
        log.notice("account \(account.id.rawValue): owned (drainer \(writable), schedulers \(kinds.map(\.rawValue).sorted()))")
        if !isActive { await runtime.setActive(false) }
        await runtime.start()
    }

    private func runtimeEnvironment() -> RuntimeEnvironment {
        let unitsPerMinute = configuration.gmail.unitsPerMinute
        var settings = SyncSettings(backfillUnitsPerMinute: max(unitsPerMinute / 2, 60))
        if let days = try? store.setting(.bodyHorizonDays, scope: .global), days > 0 {
            settings.bodyHorizon = .seconds(days * 86_400)
        }
        if let days = (try? store.setting(.metadataHorizonDays, scope: .global)) ?? nil, days > 0 {
            settings.metadataHorizon = .seconds(days * 86_400)
        }
        let sink = eventSink
        return RuntimeEnvironment(store: store, clock: configuration.clock, emit: { sink.yield($0) },
                                  connectivity: connectivity, progress: progress, reachability: reachability,
                                  pollInterval: configuration.pollInterval, syncSettings: settings,
                                  jitter: jitterOverride ?? ScheduleJitter.delay(for: store.writerID),
                                  metrics: metrics, runnerOverride: runnerOverride)
    }

    func ownershipChanged(_ account: AccountID, isOwner: Bool) async {
        eventSink.yield(.ownershipChanged(account, isOwner: isOwner))
        if isOwner {
            guard started, let item = (try? store.accounts())?.first(where: { $0.id == account }),
                  Self.isSyncable(item) else { return }
            await launchRuntime(item)
        } else {
            if let runtime = runtimes.removeValue(forKey: account) { await runtime.stop() }
            markOwnedElsewhere(account)
        }
    }

    func markOwnedElsewhere(_ account: AccountID) {
        let lease = OwnershipManager.liveOwner(account: account, store: store)
        let last = (try? store.syncStatus(account: account))?.lastSuccessAt
        connectivity.set(account, .ownedElsewhere(kind: lease?.kind ?? "unknown", lastSyncAt: last))
    }

    func requeueLeftovers() async {
        for (account, runtime) in runtimes where runtime.writable {
            let requeued = (try? store.requeueStaleInFlight(account: account, claimedBefore: configuration.clock.now)) ?? 0
            guard requeued > 0 else { continue }
            log.notice("account \(account.rawValue): requeued \(requeued) op(s) a process that ended left in flight")
            await runtime.pokeDrainer()
        }
    }

    func runMaintenanceIfDue() async {
        guard maintenanceDue(now: configuration.clock.now) else { return }
        let store = self.store
        Task.detached(priority: .utility) { _ = Self.maintenancePass(store) }
    }

    func maintenanceDue(now: Date) -> Bool {
        if let last = lastMaintenanceAt, now.timeIntervalSince(last) < Self.maintenanceEvery { return false }
        lastMaintenanceAt = now
        return true
    }

    @discardableResult
    nonisolated static func maintenancePass(_ store: MailStore, now: Date = Date()) -> MaintenanceReport? {
        try? store.garbageCollectOperations(now: now)
        return try? store.runIdleMaintenance(now: now)
    }

    private func startBackgroundTasks() {
        if let systemEvents {
            let stream = systemEvents.events
            background.append(Task { [weak self] in
                for await event in stream { await self?.handle(event) }
            })
        }
        let request = store.observeSetting(SettingKey<Int?>.syncRequestAt, scope: .global)
        background.append(Task { [weak self] in
            var first = true
            do {
                for try await _ in request.values() {
                    if first { first = false; continue }
                    await self?.pokeAllSyncs()
                    await self?.refreshAllSendAs()
                }
            } catch {}
        })
    }

    func handle(_ event: SystemEvent) async {
        switch event {
        case .didWake:
            for runtime in runtimes.values {
                await runtime.pokeSync()
                await runtime.pokeScheduler()
            }
        case .didBecomeActive:
            isActive = true
            store.setExternalChangePollActive(true)
            for runtime in runtimes.values {
                await runtime.setActive(true)
                let syncer = runtime.syncer
                Task { try? await syncer.refreshLabels() }
            }
        case .didResignActive:
            isActive = false
            store.setExternalChangePollActive(false)
            for runtime in runtimes.values { await runtime.setActive(false) }
        case .networkReachable(let up):
            let now = configuration.clock.now
            reachability.set(up, now: now)
            if up {
                for runtime in runtimes.values {
                    await runtime.pokeSync()
                    await runtime.pokeDrainer()
                }
            } else {
                let owned = Array(runtimes.keys)
                connectivity.update { states in
                    for account in owned {
                        if case .offline? = states[account] { continue }
                        states[account] = .offline(since: now)
                    }
                }
            }
        case .willTerminate:
            break
        }
    }

    func pokeAllSyncs() async {
        for runtime in runtimes.values { await runtime.pokeSync() }
    }

    func refreshAllSendAs() async {
        for (account, runtime) in runtimes {
            do {
                try await runtime.syncer.refreshSendAsOnRequest()
            } catch is CancellationError {
                return
            } catch {
                log.notice("account \(account.rawValue): send-as refresh failed (\(String(describing: type(of: error))))")
            }
        }
    }

    public func perform(_ action: MailAction, origin: OperationOrigin) async throws -> ActionReceipt {
        let accounts = EnginePolicy.accounts(in: action)
        try checkMailWrite(accounts, what: "perform")
        let receipt = try store.apply(action, origin: origin)
        await poke(accounts)
        return receipt
    }

    public func undo(_ receipt: ActionReceipt) async throws -> ActionReceipt? {
        var accounts = receipt.undo.map(EnginePolicy.accounts(in:)) ?? []
        for id in receipt.operationIDs {
            if let op = try store.operation(id) { accounts.insert(op.accountID) }
        }
        try checkMailWrite(accounts, what: "undo")
        let result = try store.undo(receipt, origin: roleOrigin)
        await poke(accounts)
        return result
    }

    public func createLabel(account: AccountID, name: String, applyTo: [ThreadRef]) async throws -> ActionReceipt {
        try await perform(.createLabel(account, name: name, applyTo: applyTo), origin: roleOrigin)
    }

    public func upsertSnippet(_ snippet: SnippetItem) async throws -> SnippetItem {
        try EnginePolicy.checkLocalWrite(role: configuration.role, what: "upsertSnippet")
        try store.upsertSnippet(snippet)
        return try store.snippets(account: snippet.accountID).first { $0.id == snippet.id } ?? snippet
    }

    public func deleteSnippet(id: String) async throws {
        try EnginePolicy.checkLocalWrite(role: configuration.role, what: "deleteSnippet")
        try store.deleteSnippet(id: id)
    }

    public func recordSnippetUse(id: String) async throws {
        try EnginePolicy.checkLocalWrite(role: configuration.role, what: "recordSnippetUse")
        try store.recordSnippetUse(id: id)
    }

    public func storeSnippetAttachment(file: URL, mimeType: String) async throws -> SnippetAttachment {
        try EnginePolicy.checkLocalWrite(role: configuration.role, what: "storeSnippetAttachment")
        return try store.storeSnippetAttachment(from: file, mimeType: mimeType)
    }

    public nonisolated func snippetFileURL(_ attachment: SnippetAttachment) -> URL? {
        store.location.snippetFileURL(attachment)
    }

    public func storeSnippetAttachment(data: Data, filename: String, mimeType: String) async throws -> SnippetAttachment {
        try EnginePolicy.checkLocalWrite(role: configuration.role, what: "storeSnippetAttachment")
        return try store.storeSnippetAttachment(data: data, filename: filename, mimeType: mimeType)
    }

    public func upsertSplit(account: AccountID, id: SplitID?, name: String, ruleText: String,
                            position: Int?, enabled: Bool) async throws -> SplitID {
        try EnginePolicy.checkLocalWrite(role: configuration.role, what: "upsertSplit")
        return try store.upsertSplit(account: account, id: id, name: name, ruleText: ruleText, position: position,
                                     enabled: enabled)
    }

    public func deleteSplit(_ id: SplitID) async throws {
        try EnginePolicy.checkLocalWrite(role: configuration.role, what: "deleteSplit")
        try store.deleteSplit(id)
    }

    public func reorderSplits(account: AccountID, _ ids: [SplitID]) async throws {
        try EnginePolicy.checkLocalWrite(role: configuration.role, what: "reorderSplits")
        try store.reorderSplits(account: account, ids)
    }

    public func waitForOperations(_ ids: [OperationID], timeout: Duration) async -> [OperationID: OperationStatus] {
        let end = ContinuousClock.now.advanced(by: timeout)
        while true {
            var statuses: [OperationID: OperationStatus] = [:]
            var settled = true
            for id in ids {
                guard let op = try? store.operation(id) else { continue }
                statuses[id] = op.status
                if op.status == .pending || op.status == .inFlight { settled = false }
            }
            if settled || ContinuousClock.now >= end || Task.isCancelled { return statuses }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func setTestSeams(jitter: Duration? = nil,
                      runnerOverride: (@Sendable (ScheduleKind, RunnerContext) -> (any ScheduleRunner)?)? = nil) {
        jitterOverride = jitter
        self.runnerOverride = runnerOverride
    }

    func runtime(for account: AccountID) -> AccountRuntime? { runtimes[account] }

    func drainer(for account: AccountID) async -> OperationDrainer? { await runtimes[account]?.drainer }

    func scheduler(for account: AccountID) async -> Scheduler? { await runtimes[account]?.scheduler }

    var roleOrigin: OperationOrigin { configuration.role == .app ? .app : .cli }

    func poke(_ accounts: Set<AccountID>) async {
        for account in accounts.sorted() {
            guard let runtime = runtimes[account] else { continue }
            await runtime.pokeDrainer()
            await runtime.pokeScheduler()
        }
    }

    func checkMailWrite(_ accounts: Set<AccountID>, what: String) throws {
        try EnginePolicy.checkMailWrite(role: configuration.role, what: what)
        try checkGrants(accounts, what: what)
    }

    func checkGrants(_ accounts: Set<AccountID>, what: String) throws {
        guard !accounts.isEmpty else { return }
        let items = try store.accounts()
        for id in accounts.sorted() {
            guard let item = items.first(where: { $0.id == id }) else { throw StoreError.notFound("account \(id.rawValue)") }
            if !EnginePolicy.grantAllowsWrites(item) {
                throw EngineError.writeAccessMissing("\(what): account \(id.rawValue) has not granted gmail.modify")
            }
        }
    }
}
