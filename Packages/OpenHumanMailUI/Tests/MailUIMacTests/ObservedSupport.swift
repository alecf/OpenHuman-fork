import Foundation
import Observation
import Synchronization

@MainActor
func untilObserved(_ condition: @MainActor () -> Bool) async {
    final class Once: Sendable {
        let continuation: Mutex<CheckedContinuation<Bool, Never>?>
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = Mutex(continuation) }
        func resume(_ value: Bool) {
            continuation.withLock { continuation in
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
    }
    while true {
        let holds = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once(continuation)
            let met = withObservationTracking { condition() } onChange: { once.resume(false) }
            if met { once.resume(true) }
        }
        if holds { return }
    }
}
