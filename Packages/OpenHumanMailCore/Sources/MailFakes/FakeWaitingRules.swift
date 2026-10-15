import Foundation
import MailModel
import Synchronization

public final class FakeWaitingRules: WaitingPort, Sendable {
    private struct State {
        var choices: [ThreadKey: WaitingChoice] = [:]
        var known: Set<ThreadKey>?
        var failNext: MailPortError?
    }

    private let state: Mutex<State>

    public init(knownThreads: Set<ThreadKey>? = nil) {
        state = Mutex(State(known: knownThreads))
    }

    public var choices: [ThreadKey: WaitingChoice] { state.withLock { $0.choices } }

    public func failNext(_ error: MailPortError) { state.withLock { $0.failNext = error } }

    public func setChoice(_ choice: WaitingChoice?, for thread: ThreadKey) async throws -> UndoToken {
        try state.withLock { s in
            try Self.check(&s, thread)
            let previous = s.choices[thread]
            s.choices[thread] = choice
            return try WaitingReceipt(thread: thread, restore: previous).token()
        }
    }

    public func undo(_ token: UndoToken) async throws -> UndoToken? {
        let receipt = try WaitingReceipt(token: token)
        return try state.withLock { s in
            try Self.check(&s, receipt.thread)
            let current = s.choices[receipt.thread]
            s.choices[receipt.thread] = receipt.restore
            return try WaitingReceipt(thread: receipt.thread, restore: current).token()
        }
    }

    private static func check(_ s: inout State, _ thread: ThreadKey) throws {
        if let failure = s.failNext {
            s.failNext = nil
            throw failure
        }
        if let known = s.known, !known.contains(thread) { throw MailPortError.notFound("thread") }
    }
}
