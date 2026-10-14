// GRDB only sees commits from its own pool, so writes post a Darwin notification for other processes to pick up
import Dispatch
import Foundation
import OpenHumanCore
import Synchronization
#if canImport(Darwin)
import Darwin
import notify
#endif

final class ExternalChangeMonitor: Sendable {
    struct PollPolicy: Equatable {
        var active: TimeInterval
        var inactive: TimeInterval
        var leewayFraction: Double
        static let standard = PollPolicy(active: 30, inactive: 60, leewayFraction: 0.1)
        static let pollOnlyTestHook = PollPolicy(active: 1, inactive: 10, leewayFraction: 0.1)
        func interval(active isActive: Bool) -> TimeInterval { isActive ? active : inactive }
        func leeway(active isActive: Bool) -> DispatchTimeInterval {
            .milliseconds(Int(interval(active: isActive) * leewayFraction * 1_000))
        }
    }

    private struct State {
        var others: [String: Int64]?
        var token: Int32 = 0
        var registered = false
        var timer: (any DispatchSourceTimer)?
        var stopped = false
        var policy = PollPolicy.standard
        var pollInterval: TimeInterval?
    }

    private let queue = DispatchQueue(label: "dev.openhuman.mail.store.monitor")
    private let state = Mutex(State())
    let notificationName: String
    private let readOthers: @Sendable () throws -> [String: Int64]
    private let pulse: @Sendable () throws -> Void
    private let log = Log(.store)
    private var policy: PollPolicy { state.withLock { $0.policy } }

    init(notificationName: String = OHIdentifiers.storeChangedNotification,
         readOthers: @escaping @Sendable () throws -> [String: Int64], pulse: @escaping @Sendable () throws -> Void) {
        self.notificationName = notificationName
        self.readOthers = readOthers
        self.pulse = pulse
    }

    var currentPollInterval: TimeInterval? { state.withLock { $0.pollInterval } }

    func start(active: Bool = true, poll: Bool = true) {
        queue.sync {
            if ProcessInfo.processInfo.environment["OPENHUMAN_STORE_POLL_ONLY"] == "1" { state.withLock { $0.policy = .pollOnlyTestHook } }
            guard !state.withLock({ $0.stopped }) else { return }
            state.withLock { $0.others = (try? readOthers()) ?? [:] }
            #if canImport(Darwin)
            if ProcessInfo.processInfo.environment["OPENHUMAN_STORE_POLL_ONLY"] != "1" {
                var token: Int32 = 0
                let status = notify_register_dispatch(notificationName, &token, queue) { [weak self] _ in
                    self?.performCheck()
                }
                if status == NOTIFY_STATUS_OK {
                    state.withLock { $0.token = token; $0.registered = true }
                }
            }
            #endif
            if poll { schedulePoll(active: active) }
        }
    }

    func setActive(_ active: Bool) {
        queue.sync { if !state.withLock({ $0.stopped }) { schedulePoll(active: active) } }
    }

    func stop() {
        queue.sync {
            let (timer, token, registered): ((any DispatchSourceTimer)?, Int32, Bool) = state.withLock {
                $0.stopped = true
                let snapshot = ($0.timer, $0.token, $0.registered)
                $0.timer = nil
                $0.pollInterval = nil
                $0.registered = false
                return snapshot
            }
            timer?.cancel()
            #if canImport(Darwin)
            if registered { notify_cancel(token) }
            #endif
        }
    }

    @discardableResult
    func checkNow() -> Bool { queue.sync { performCheck() } }

    private func schedulePoll(active: Bool) {
        let interval = policy.interval(active: active)
        if state.withLock({ $0.timer != nil && $0.pollInterval == interval }) { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: policy.leeway(active: active))
        timer.setEventHandler { [weak self] in self?.performCheck() }
        let old = state.withLock { s -> (any DispatchSourceTimer)? in
            let previous = s.timer
            s.timer = timer
            s.pollInterval = interval
            return previous
        }
        old?.cancel()
        timer.resume()
    }

    @discardableResult
    private func performCheck() -> Bool {
        guard !state.withLock({ $0.stopped }) else { return false }
        do {
            let current = try readOthers()
            let previous = state.withLock { $0.others } ?? [:]
            let changed = current.contains { previous[$0.key] != $0.value }
            guard changed else {
                state.withLock { $0.others = current }
                return false
            }
            try pulse()
            state.withLock { $0.others = current }
            return true
        } catch {
            log.error("external change check failed (\(storeLogCode(error)))")
            return false
        }
    }
}
