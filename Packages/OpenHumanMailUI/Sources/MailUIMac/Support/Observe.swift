import Foundation
import Observation

@MainActor
public final class ObservationLoop {
    private var active = true

    public func cancel() { active = false }

    @discardableResult
    public static func observe(_ apply: @escaping @MainActor () -> Void) -> ObservationLoop {
        let loop = ObservationLoop()
        loop.arm(apply)
        return loop
    }

    private func arm(_ apply: @escaping @MainActor () -> Void) {
        guard active else { return }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.arm(apply) }
        }
    }
}
