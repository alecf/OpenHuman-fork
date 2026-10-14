import Foundation
import Observation
import Synchronization
import Testing

@MainActor
func eventually(timeout: Duration? = nil, _ condition: @MainActor () -> Bool,
                sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let deadline = clock.now + testBackstop
    while !condition() {
        if clock.now > deadline {
            Issue.record("condition not met within the \(testBackstop) backstop", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

let testBackstop: Duration = .seconds(120)

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

let fixedNow = Date(timeIntervalSince1970: 1_791_000_000)
