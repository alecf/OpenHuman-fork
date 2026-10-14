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

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class SizeReportingHostingView<Content: View>: NSHostingView<Content> {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var invalidated = false

    required init(rootView: Content) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        changed()
    }

    override var needsLayout: Bool {
        didSet { if needsLayout { changed() } }
    }

    override var needsUpdateConstraints: Bool {
        didSet { if needsUpdateConstraints { changed() } }
    }

    private func changed() {
        invalidated = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    func layout(until condition: () -> Bool) async {
        while true {
            invalidated = false
            layoutSubtreeIfNeeded()
            if condition() { return }
            if invalidated { continue }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
#endif
