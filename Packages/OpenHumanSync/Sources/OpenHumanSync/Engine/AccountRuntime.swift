import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

struct RuntimeEnvironment: Sendable {
    let store: MailStore
    let clock: any OHClock
    let emit: @Sendable (EngineEvent) -> Void
    let connectivity: ConnectivityHub
    let progress: ProgressHub
    let reachability: Reachability
    let pollInterval: Duration
    let syncSettings: SyncSettings
    let jitter: Duration
    let metrics: @Sendable (String) -> SyncMetricsCollector?
    let runnerOverride: (@Sendable (ScheduleKind, RunnerContext) -> (any ScheduleRunner)?)?
}

actor AccountRuntime {
    enum PollState: Sendable, Equatable { case idle, running, stoppedNeedsReauth, stopped }

    static let syncAfterWrite: Duration = .seconds(3)
    static let scheduleLabelWarning = 2_000

    nonisolated let account: AccountID
    nonisolated let email: String
    nonisolated let api: any GmailAPI
    nonisolated let syncer: AccountSyncer
    nonisolated let gate: BackfillGate
    nonisolated let writable: Bool
    nonisolated let drainsExternalOps: Bool
    nonisolated let schedulerKinds: Set<ScheduleKind>
    private let env: RuntimeEnvironment
    private let log = Log(.sync)

    private(set) var drainer: OperationDrainer?
    private(set) var scheduler: Scheduler?
    private(set) var pollState: PollState = .idle
    private(set) var completedRuns = 0
    private(set) var failedRuns = 0
    private(set) var nextPollAt: Date?
    private(set) var syncSoonAt: Date?
    private(set) var active = true
    private var pollTask: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    private var poked = false
    private var syncSoonTask: Task<Void, Never>?
    private var watchers: [Task<Void, Never>] = []
    private var lastReportedPhase: SyncPhase?
    private var lastReportedOldest: Date?
    private var budgetWarned = false

    init(account: AccountItem, api: any GmailAPI, writable: Bool, drainsExternalOps: Bool = false,
         schedulerKinds: Set<ScheduleKind>, env: RuntimeEnvironment) {
        self.account = account.id
        self.email = account.email
        self.api = api
        self.writable = writable
        self.drainsExternalOps = drainsExternalOps
        self.schedulerKinds = schedulerKinds
        self.env = env
        let reachability = env.reachability
        let gate = BackfillGate(isReachable: { reachability.isReachable })
        self.gate = gate
        let store = env.store
        syncer = AccountSyncer(account: account.id, store: env.store, api: api, clock: env.clock,
                               settings: env.syncSettings, metrics: env.metrics(account.email), gate: gate,
                               bodyPolicy: { Self.bodyPolicy(store) }, muting: writable ? env.store : nil,
                               blocking: writable ? env.store : nil)
    }

    static func bodyPolicy(_ store: MailStore) -> BodyDownloadPolicy {
        BodyDownloadPolicy(enabled: (try? store.setting(.downloadBodies, scope: .global)) ?? true,
                           maxMessages: ((try? store.setting(.bodyMaxMessages, scope: .global)) ?? nil))
    }

    func start() async {
        guard pollState == .idle else { return }
        pollState = .running
        let last = (try? env.store.syncStatus(account: account))?.lastSuccessAt
        env.connectivity.set(account, .online(syncing: true, lastSyncAt: last))
        if writable {
            let drainer = OperationDrainer(account: account, store: env.store, api: api, clock: env.clock,
                                           emit: env.emit,
                                           onApplied: { [weak self] appliedAt in
                                               Task { await self?.syncSoon(after: appliedAt) }
                                           },
                                           gate: gate, drainsExternalOps: drainsExternalOps)
            self.drainer = drainer
            await drainer.start()
        }
        if !schedulerKinds.isEmpty { scheduler = makeScheduler() }
        startWatchers()
        pollTask = Task { await self.pollLoop() }
    }

    func stop() async {
        pollState = .stopped
        pollTask?.cancel()
        pollTask = nil
        sleeper?.cancel()
        syncSoonTask?.cancel()
        for watcher in watchers { watcher.cancel() }
        watchers = []
        env.progress.set(account, nil)
        await scheduler?.stop()
        await drainer?.stop()
        await syncer.cancel()
    }

    func pokeSync() {
        poked = true
        sleeper?.cancel()
    }

    func pokeDrainer() async { await drainer?.poke() }

    func pokeScheduler() async { await scheduler?.poke() }

    func setActive(_ isActive: Bool) {
        let wasActive = active
        active = isActive
        if isActive && !wasActive { pokeSync() }
    }

    func syncSoon(after appliedAt: Date) {
        guard pollState != .stopped else { return }
        let deadline = appliedAt.addingTimeInterval(Self.syncAfterWrite.timeInterval)
        if let armed = syncSoonAt, armed >= deadline { return }
        syncSoonTask?.cancel()
        let clock = env.clock
        syncSoonAt = deadline
        syncSoonTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            await self?.syncSoonFired(deadline)
        }
    }

    private func syncSoonFired(_ deadline: Date) {
        if syncSoonAt == deadline { syncSoonAt = nil }
        pokeSync()
    }

    func syncNow(reason: String) async throws -> SyncReport {
        guard pollState != .stopped else {
            throw EngineError.requiresApp("account \(account.rawValue) is not synced by this process")
        }
        let result = await runSync(reason: reason)
        await scheduler?.poke()
        return try result.get()
    }

    private func pollLoop() async {
        var first = true
        while !Task.isCancelled {
            poked = false
            nextPollAt = nil
            _ = await runSync(reason: first ? "launch" : "poll")
            if Task.isCancelled { break }
            if first {
                first = false
                await scheduler?.start()
            } else {
                await scheduler?.poke()
            }
            if pollState == .stoppedNeedsReauth {
                pollTask = nil
                break
            }
            if poked { continue }
            let failures = (try? env.store.syncStatus(account: account).consecutiveFailures) ?? 0
            let base = active ? env.pollInterval : env.pollInterval * 3
            let delay = PollSchedule.delay(base: base, consecutiveFailures: failures)
            let clock = env.clock
            let wake = clock.now.addingTimeInterval(delay.timeInterval)
            nextPollAt = wake
            let nap = Task { try await clock.sleep(until: wake) }
            sleeper = nap
            _ = try? await nap.value
            sleeper = nil
        }
    }

    private func runSync(reason: String) async -> Result<SyncReport, Error> {
        env.connectivity.update { states in
            if case let .online(_, last)? = states[account] { states[account] = .online(syncing: true, lastSyncAt: last) }
        }
        do {
            let report = try await syncer.sync(reason: reason)
            completedRuns += 1
            await afterSuccess()
            return .success(report)
        } catch {
            if Task.isCancelled || AccountSyncer.code(error) == "cancelled" { return .failure(error) }
            failedRuns += 1
            await afterFailure(error)
            return .failure(error)
        }
    }

    private func afterSuccess() async {
        let status = try? env.store.syncStatus(account: account)
        if pollState == .stoppedNeedsReauth {
            pollState = .running
            if pollTask == nil { pollTask = Task { await self.pollLoop() } }
        }
        env.connectivity.set(account, .online(syncing: false, lastSyncAt: status?.lastSuccessAt ?? env.clock.now))
        reportPhase(status)
        warnAboutScheduleLabels()
        await syncer.startBackfill()
    }

    private func afterFailure(_ error: Error) async {
        let code = AccountSyncer.code(error)
        let now = env.clock.now
        let last = (try? env.store.syncStatus(account: account))?.lastSuccessAt
        env.connectivity.update { states in
            states[account] = ConnectivityHub.afterFailure(error, now: now, previous: states[account], lastSyncAt: last)
        }
        env.emit(.syncFailed(account, code))
        if case GmailError.reauthRequired = error {
            pollState = .stoppedNeedsReauth
            env.emit(.accountNeedsReauth(account))
            await syncer.stopBackfill()
        }
    }

    private func reportPhase(_ status: SyncStatus?) {
        guard let status else { return }
        guard status.phase != lastReportedPhase || status.backfillOldest != lastReportedOldest else { return }
        lastReportedPhase = status.phase
        lastReportedOldest = status.backfillOldest
        env.emit(.initialSyncProgress(account, phase: status.phase, oldest: status.backfillOldest))
    }

    private func progressChanged(_ value: SyncProgress) {
        guard pollState != .stopped else { return }
        env.progress.set(account, value)
        reportPhase(try? env.store.syncStatus(account: account))
    }

    private func warnAboutScheduleLabels() {
        guard !budgetWarned, let labels = try? env.store.labels(account: account) else { return }
        let count = labels.reduce(0) { n, label in
            if case .schedule = ScheduleLabel.parse(label.name) { return n + 1 }
            return n
        }
        guard count > Self.scheduleLabelWarning else { return }
        budgetWarned = true
        log.notice("account \(account.rawValue): \(count) schedule labels")
        env.emit(.scheduleLabelBudget(account, count: count))
    }

    private func makeScheduler() -> Scheduler {
        let reachability = env.reachability
        let context = RunnerContext(account: account, store: env.store, syncer: syncer, api: api, clock: env.clock,
                                    jitter: env.jitter, emit: env.emit,
                                    pokeDrainer: { [weak self] in await self?.pokeDrainer() },
                                    isReachable: { reachability.isReachable }, labelsFreshness: LabelsFreshness())
        var runners: [any ScheduleRunner] = []
        for kind in [ScheduleKind.reminder, .snooze, .sendLater] where schedulerKinds.contains(kind) {
            if let replacement = env.runnerOverride?(kind, context) {
                runners.append(replacement)
                continue
            }
            switch kind {
            case .reminder: runners.append(ReminderRunner(context))
            case .snooze: runners.append(SnoozeRunner(context))
            case .sendLater: runners.append(SendLaterRunner(context))
            }
        }
        let store = env.store
        return Scheduler(account: account, runners: runners, clock: env.clock,
                         isEnabled: { kind in (try? store.setting(EnginePolicy.settingKey(kind), scope: .global)) ?? true },
                         emit: env.emit)
    }

    private func startWatchers() {
        let store = env.store
        let account = self.account
        if writable {
            watchers.append(Task { [weak self] in
                var last = -1
                do {
                    for try await status in store.observeSyncStatus(account: account).values() {
                        if status.pendingOperations > last { await self?.pokeDrainer() }
                        last = status.pendingOperations
                    }
                } catch {}
            })
        }
        if scheduler != nil {
            watchers.append(Self.watch(store.observeReminders(account: account)) { [weak self] in await self?.pokeScheduler() })
            watchers.append(Self.watch(store.observeDrafts(account: account, states: [.scheduled])) { [weak self] in
                await self?.pokeScheduler()
            })
            for kind in schedulerKinds {
                watchers.append(Self.watch(store.observeSetting(EnginePolicy.settingKey(kind), scope: .global)) { [weak self] in
                    await self?.pokeScheduler()
                })
            }
        }
        watchers.append(Self.watch(store.observeSetting(SettingKey<Bool>.downloadBodies, scope: .global)) { [weak self] in
            await self?.syncer.bodySettingsChanged()
        })
        watchers.append(Self.watch(store.observeSetting(SettingKey<Int?>.bodyMaxMessages, scope: .global)) { [weak self] in
            await self?.syncer.bodySettingsChanged()
        })
        let progress = syncer.observeProgress()
        watchers.append(Task { [weak self] in
            for await value in progress { await self?.progressChanged(value) }
        })
    }

    private static func watch<T>(_ observation: StoreObservation<T>,
                                 onChange: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task {
            var first = true
            do {
                for try await _ in observation.values() {
                    if first { first = false; continue }
                    await onChange()
                }
            } catch {}
        }
    }
}
