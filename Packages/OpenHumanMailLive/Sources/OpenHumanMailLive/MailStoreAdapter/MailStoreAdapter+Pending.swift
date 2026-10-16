import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore
import Synchronization

extension MailStoreAdapter {
    public func pendingChanges() -> AsyncStream<[AccountID: Int]> {
        let store = self.store
        return AsyncStream { continuation in
            let tally = PendingTally(continuation)
            let accounts = Task {
                do {
                    for try await items in store.observeAccounts().values() {
                        tally.follow(items.map(\.id)) { id in
                            Task {
                                do {
                                    for try await status in store.observeSyncStatus(account: id).values() {
                                        tally.set(id, status.pendingOperations)
                                    }
                                } catch {}
                            }
                        }
                    }
                } catch {}
            }
            continuation.onTermination = { _ in
                accounts.cancel()
                tally.stop()
            }
        }
    }
}

private final class PendingTally: Sendable {
    private struct State {
        var counts: [AccountID: Int] = [:]
        var watchers: [AccountID: Task<Void, Never>] = [:]
        var last: [AccountID: Int]?
        var stopped = false
    }
    private let state = Mutex(State())
    private let continuation: AsyncStream<[AccountID: Int]>.Continuation

    init(_ continuation: AsyncStream<[AccountID: Int]>.Continuation) { self.continuation = continuation }

    func follow(_ ids: [AccountID], start: (AccountID) -> Task<Void, Never>) {
        let keep = Set(ids)
        let removed = state.withLock { s -> [Task<Void, Never>] in
            guard !s.stopped else { return [] }
            var gone: [Task<Void, Never>] = []
            for (id, task) in s.watchers where !keep.contains(id) {
                gone.append(task)
                s.watchers[id] = nil
                s.counts[id] = nil
            }
            for id in ids where s.watchers[id] == nil { s.watchers[id] = start(id) }
            return gone
        }
        for task in removed { task.cancel() }
        emit()
    }

    func set(_ id: AccountID, _ count: Int) {
        state.withLock { s in if !s.stopped, s.watchers[id] != nil { s.counts[id] = count } }
        emit()
    }

    func stop() {
        let tasks = state.withLock { s -> [Task<Void, Never>] in
            s.stopped = true
            let all = Array(s.watchers.values)
            s.watchers = [:]
            return all
        }
        for task in tasks { task.cancel() }
    }

    private func emit() {
        let next = state.withLock { s -> [AccountID: Int]? in
            guard !s.stopped else { return nil }
            let now = s.counts.filter { $0.value > 0 }
            if s.last == now { return nil }
            s.last = now
            return now
        }
        if let next { continuation.yield(next) }
    }
}
