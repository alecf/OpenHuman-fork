import Foundation
import Synchronization

public struct StoreObservation<Value: Sendable & Equatable>: Sendable {
    private let makeStream: @Sendable () -> AsyncThrowingStream<Value, Error>
    private let currentValue: (@Sendable () throws -> Value)?

    public init(values: @escaping @Sendable () -> AsyncThrowingStream<Value, Error>,
                current: (@Sendable () throws -> Value)? = nil) {
        makeStream = values
        currentValue = current
    }

    public func values() -> AsyncThrowingStream<Value, Error> { makeStream() }

    @MainActor
    public func start(scheduling: ObservationScheduling = .immediate,
                      onError: @escaping @MainActor (Error) -> Void,
                      onChange: @escaping @MainActor (Value) -> Void) -> ObservationToken {
        var last: Value?
        if scheduling == .immediate, let currentValue {
            do {
                let value = try currentValue()
                last = value
                onChange(value)
            } catch {
                onError(error)
            }
        }
        let stream = makeStream()
        let task = Task { @MainActor [last] in
            var previous = last
            do {
                for try await value in stream {
                    if value != previous {
                        previous = value
                        onChange(value)
                    }
                }
            } catch is CancellationError {
            } catch {
                onError(error)
            }
        }
        return ObservationToken { task.cancel() }
    }
}

public enum ObservationScheduling: Sendable { case immediate, async }

public final class ObservationToken: Sendable {
    private let onCancel: Mutex<(@Sendable () -> Void)?>

    public init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = Mutex(onCancel)
    }

    public func cancel() {
        let action = onCancel.withLock { value -> (@Sendable () -> Void)? in
            defer { value = nil }
            return value
        }
        action?()
    }

    deinit { cancel() }
}
