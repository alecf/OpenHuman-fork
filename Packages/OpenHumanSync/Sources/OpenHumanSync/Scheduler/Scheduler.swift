import Foundation
import OpenHumanCore
import OpenHumanStore

actor Scheduler {
    struct Health: Sendable, Equatable {
        var consecutiveFailures = 0
        var suspensions = 0
        var suspendedUntil: Date?
    }

    static let failuresBeforeSuspension = 3
    static let firstSuspension: Duration = .seconds(900)
    static let maxSuspension: Duration = .seconds(7_200)
    static let retryWhileDue: Duration = .seconds(60)
    static let maxNap: Duration = .seconds(900)

    nonisolated let account: AccountID
    private let runners: [any ScheduleRunner]
    private let isEnabled: @Sendable (ScheduleKind) -> Bool
    private let clock: any OHClock
    private let emit: @Sendable (EngineEvent) -> Void
    private let log = Log(.scheduler)

    private(set) var health: [ScheduleKind: Health] = [:]
    private(set) var passes = 0
    private(set) var nextFire: Date?
    private var loopTask: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    private var poked = false

    init(account: AccountID, runners: [any ScheduleRunner], clock: any OHClock,
         isEnabled: @escaping @Sendable (ScheduleKind) -> Bool,
         emit: @escaping @Sendable (EngineEvent) -> Void) {
        self.account = account
        self.runners = runners
        self.clock = clock
        self.isEnabled = isEnabled
        self.emit = emit
    }

    var kinds: [ScheduleKind] { runners.map(\.kind) }
    var isRunning: Bool { loopTask != nil }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { await self.loop() }
    }

    func poke() {
        poked = true
        sleeper?.cancel()
    }

    func stop() {
        loopTask?.cancel()
        sleeper?.cancel()
        loopTask = nil
        nextFire = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            poked = false
            nextFire = nil
            let now = clock.now
            await runPass(now: now)
            if Task.isCancelled { break }
            if poked { continue }
            let wake = await nextWake(passedAt: now)
            if poked || Task.isCancelled { continue }
            nextFire = wake
            let clock = self.clock
            let nap = Task { try await clock.sleep(until: wake) }
            sleeper = nap
            _ = try? await nap.value
            sleeper = nil
        }
    }

    func runPass(now: Date) async {
        passes += 1
        let active = runners.filter { runner in
            guard isEnabled(runner.kind) else { return false }
            guard let until = health[runner.kind]?.suspendedUntil else { return true }
            return now >= until
        }
        guard !active.isEmpty else { return }
        let account = self.account
        let results = await withTaskGroup(of: (ScheduleKind, String?).self) { group in
            for runner in active {
                group.addTask {
                    do {
                        try await runner.reconcile(account: account, now: now)
                        return (runner.kind, nil)
                    } catch is CancellationError {
                        return (runner.kind, nil)
                    } catch {
                        return (runner.kind, AccountSyncer.code(error))
                    }
                }
            }
            var out: [(ScheduleKind, String?)] = []
            for await result in group { out.append(result) }
            return out
        }
        if Task.isCancelled { return }
        for (kind, failure) in results { record(kind, failure: failure, now: now) }
    }

    private func record(_ kind: ScheduleKind, failure: String?, now: Date) {
        var h = health[kind] ?? Health()
        guard let failure else {
            if h != Health() { log.info("account \(account.rawValue): \(kind.rawValue) runner healthy again") }
            health[kind] = Health()
            return
        }
        h.consecutiveFailures += 1
        log.error("account \(account.rawValue): \(kind.rawValue) runner failed (\(failure)), \(h.consecutiveFailures) in a row")
        if h.consecutiveFailures >= Self.failuresBeforeSuspension {
            let seconds = min(Self.firstSuspension.timeInterval * pow(2, Double(min(h.suspensions, 10))),
                              Self.maxSuspension.timeInterval)
            h.suspendedUntil = now.addingTimeInterval(seconds)
            h.suspensions += 1
            h.consecutiveFailures = 0
            log.error("account \(account.rawValue): \(kind.rawValue) runner suspended for \(Int(seconds)) s")
            emit(.schedulerDegraded(kind, "\(failure); suspended for \(Int(seconds / 60)) min"))
        }
        health[kind] = h
    }

    private func nextWake(passedAt: Date) async -> Date {
        let now = clock.now
        var wake = now.addingTimeInterval(Self.maxNap.timeInterval)
        for runner in runners where isEnabled(runner.kind) {
            if let until = health[runner.kind]?.suspendedUntil, until > now {
                wake = min(wake, until)
                continue
            }
            let due: Date?
            do { due = try await runner.nextDue(account: account, now: now) } catch {
                log.error("account \(account.rawValue): \(runner.kind.rawValue) next due time unreadable (\(AccountSyncer.code(error)))")
                continue
            }
            guard let due else { continue }
            wake = min(wake, due <= passedAt ? passedAt.addingTimeInterval(Self.retryWhileDue.timeInterval) : due)
        }
        return wake
    }
}
