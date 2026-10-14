import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

public enum PollSchedule {
    public static let maxBackoff: Duration = .seconds(900)

    public static func delay(base: Duration, consecutiveFailures n: Int) -> Duration {
        guard n > 0 else { return base }
        let seconds = min(base.timeInterval * pow(2, Double(min(n, 30))), maxBackoff.timeInterval)
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }
}

public actor SyncLoop {
    public enum State: Sendable, Equatable { case idle, running, stoppedNeedsReauth, stopped }

    public let syncer: AccountSyncer
    private let store: any MailReading
    private let clock: any OHClock
    private let interval: Duration
    private let backfill: Bool
    private var loopTask: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    private var poked = false
    public private(set) var state: State = .idle
    public private(set) var completedRuns = 0
    public private(set) var failedRuns = 0
    public private(set) var lastDelay: Duration?

    public init(syncer: AccountSyncer, store: any MailReading, clock: any OHClock, interval: Duration = .seconds(60),
                backfill: Bool = false) {
        self.syncer = syncer
        self.store = store
        self.clock = clock
        self.interval = interval
        self.backfill = backfill
    }

    public func start() {
        guard loopTask == nil else { return }
        state = .running
        loopTask = Task { await self.loop() }
    }

    public func stop() async {
        loopTask?.cancel()
        sleeper?.cancel()
        loopTask = nil
        if state == .running { state = .stopped }
        if backfill { await syncer.stopBackfill() }
    }

    public func poke() {
        poked = true
        sleeper?.cancel()
    }

    private func loop() async {
        while !Task.isCancelled {
            poked = false
            do {
                try await syncer.sync(reason: "poll")
                completedRuns += 1
                if backfill && !Task.isCancelled { await syncer.startBackfill() }
            } catch GmailError.reauthRequired {
                failedRuns += 1
                state = .stoppedNeedsReauth
                loopTask = nil
                await syncer.stopBackfill()
                return
            } catch {
                if Task.isCancelled { break }
                failedRuns += 1
            }
            if Task.isCancelled { break }
            let failures = (try? store.syncStatus(account: syncer.account).consecutiveFailures) ?? 0
            let delay = PollSchedule.delay(base: interval, consecutiveFailures: failures)
            lastDelay = delay
            if poked { continue }
            let clock = self.clock
            let nap = Task { try await clock.sleep(for: delay) }
            sleeper = nap
            _ = try? await nap.value
            sleeper = nil
        }
        if state == .running { state = .stopped }
    }
}
