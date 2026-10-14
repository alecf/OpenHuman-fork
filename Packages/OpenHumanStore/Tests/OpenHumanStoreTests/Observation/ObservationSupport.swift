import Foundation
import Synchronization
import Testing
@testable import OpenHumanStore

final class Collector<Value: Sendable & Equatable>: Sendable {
    private struct State {
        var values: [Value] = []
        var error: (any Error)?
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private final class Box: Sendable {
        let state = Mutex(State())

        func update(_ change: (inout State) -> Void) {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                change(&state)
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }

        func change(after count: Int) async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let now = state.withLock { state -> Bool in
                        if state.values.count != count || state.finished || Task.isCancelled { return true }
                        state.waiters.append(continuation)
                        return false
                    }
                    if now { continuation.resume() }
                }
            } onCancel: {
                update { _ in }
            }
        }
    }
    private let box = Box()
    private let task: Task<Void, Never>

    init(_ observation: StoreObservation<Value>) {
        let box = self.box
        let stream = observation.values()
        task = Task {
            do {
                for try await value in stream { box.update { $0.values.append(value) } }
                box.update { $0.finished = true }
            } catch { box.update { $0.error = error; $0.finished = true } }
        }
    }

    var values: [Value] { box.state.withLock { $0.values } }
    var error: (any Error)? { box.state.withLock { $0.error } }
    var finished: Bool { box.state.withLock { $0.finished } }

    @discardableResult
    func wait(until condition: ([Value]) -> Bool) async -> Bool {
        while true {
            let (values, finished) = box.state.withLock { ($0.values, $0.finished) }
            if condition(values) { return true }
            if finished || Task.isCancelled { return false }
            await box.change(after: values.count)
        }
    }

    func waitForCount(_ n: Int) async -> Bool { await wait { $0.count >= n } }

    func waitForEnd() async {
        _ = await wait { _ in false }
    }

    func stop() { task.cancel() }
    deinit { task.cancel() }
}

func waitUntil(timeout: Duration = .seconds(15), isolation: isolated (any Actor)? = #isolation,
               _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + max(timeout, .seconds(120))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
