import Foundation
import MailModel
import Synchronization

public final class FakeCalendarConnection: CalendarConnecting, Sendable {
    private struct State {
        var current: CalendarConnectionState
        var running: Bool
        var grantsWrites: Bool
        var watchers: [UUID: AsyncStream<CalendarConnectionState>.Continuation] = [:]
        var connectCalls = 0
        var connectClients: [String?] = []
        var disconnectCalls = 0
        var failure: String?

        mutating func settle() {
            current.needsRestart = (current.status == .connected) != running
        }
    }
    private let state: Mutex<State>

    public init(account: String = "me@example.com", connected: Bool = false, grantsWrites: Bool = true,
                running: Bool? = nil) {
        var initial = State(current: CalendarConnectionState(status: connected ? .connected : .disconnected, account: account,
                                                             canCreateEvents: connected && grantsWrites),
                            running: running ?? connected, grantsWrites: grantsWrites)
        initial.settle()
        state = Mutex(initial)
    }

    public func connectionStates() -> AsyncStream<CalendarConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CalendarConnectionState>.makeStream()
        let current = state.withLock { s -> CalendarConnectionState in
            s.watchers[id] = continuation
            return s.current
        }
        continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.watchers.removeValue(forKey: id) } }
        continuation.yield(current)
        return stream
    }

    public func connect() async throws {
        try await connect(client: nil)
    }

    public func connect(client: String?) async throws {
        let failure = state.withLock { s -> String? in
            s.connectCalls += 1
            s.connectClients.append(client)
            return s.failure
        }
        if let failure { throw CalendarError.failed(failure) }
        publish { s in
            s.current.status = .connected
            s.current.canCreateEvents = s.grantsWrites
        }
    }

    public func disconnect() async throws {
        state.withLock { $0.disconnectCalls += 1 }
        publish { s in
            s.current.status = .disconnected
            s.current.canCreateEvents = false
        }
    }

    public var current: CalendarConnectionState { state.withLock { $0.current } }
    public var connectCalls: Int { state.withLock { $0.connectCalls } }
    public var connectClients: [String?] { state.withLock { $0.connectClients } }
    public var disconnectCalls: Int { state.withLock { $0.disconnectCalls } }
    public var failure: String? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    public func expire() {
        publish { $0.current.status = .needsReconnect }
    }

    private func publish(_ change: (inout State) -> Void) {
        let (current, watchers) = state.withLock { s -> (CalendarConnectionState, [AsyncStream<CalendarConnectionState>.Continuation]) in
            change(&s)
            s.settle()
            return (s.current, Array(s.watchers.values))
        }
        for watcher in watchers { watcher.yield(current) }
    }
}
