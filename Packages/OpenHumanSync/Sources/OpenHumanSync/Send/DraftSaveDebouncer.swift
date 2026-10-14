import Foundation
import OpenHumanCore
import OpenHumanStore

public actor DraftSaveDebouncer {
    public static let interval: Duration = .seconds(5)

    private let store: MailStore
    private let clock: any OHClock
    private let interval: Duration
    private let onEnqueued: @Sendable (DraftID, OperationID) -> Void
    private let log = Log(.queue)
    private var timers: [DraftID: (token: UInt64, task: Task<Void, Never>)] = [:]
    private var nextToken: UInt64 = 0

    public init(store: MailStore, clock: any OHClock, interval: Duration = DraftSaveDebouncer.interval,
                onEnqueued: @escaping @Sendable (DraftID, OperationID) -> Void = { _, _ in }) {
        self.store = store
        self.clock = clock
        self.interval = interval
        self.onEnqueued = onEnqueued
    }

    public func noteEdit(_ id: DraftID) {
        guard timers[id] == nil else { return }
        let clock = self.clock, deadline = clock.now.addingTimeInterval(interval.timeInterval)
        nextToken += 1
        let token = nextToken
        timers[id] = (token, Task {
            do { try await clock.sleep(until: deadline) } catch { return }
            self.fire(id, token: token)
        })
    }

    @discardableResult
    public func flush(_ id: DraftID) -> OperationID? {
        timers.removeValue(forKey: id)?.task.cancel()
        return enqueue(id)
    }

    public func flushAll() {
        for id in timers.keys.sorted(by: { $0.rawValue < $1.rawValue }) { flush(id) }
    }

    public func cancel(_ id: DraftID) {
        timers.removeValue(forKey: id)?.task.cancel()
    }

    public var pending: Set<DraftID> { Set(timers.keys) }

    private func fire(_ id: DraftID, token: UInt64) {
        guard timers[id]?.token == token else { return }
        timers[id] = nil
        enqueue(id)
    }

    @discardableResult
    private func enqueue(_ id: DraftID) -> OperationID? {
        do {
            let op = try store.saveDraftRemotely(id)
            onEnqueued(id, op)
            return op
        } catch {
            log.notice("draft \(id.rawValue): remote save skipped (\(String(describing: type(of: error))))")
            return nil
        }
    }
}
