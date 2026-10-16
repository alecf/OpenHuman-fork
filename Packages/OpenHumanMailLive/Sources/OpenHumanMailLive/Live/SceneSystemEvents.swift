import Foundation
import Network
import OpenHumanSync
import SwiftUI
import Synchronization

public final class SceneSystemEvents: StoppableSystemEvents {
    public let events: AsyncStream<SystemEvent>
    private let continuation: AsyncStream<SystemEvent>.Continuation
    private let monitor: NWPathMonitor?
    private let reachable = Mutex(true)

    public init(monitorsNetwork: Bool = true) {
        (events, continuation) = AsyncStream.makeStream(of: SystemEvent.self, bufferingPolicy: .bufferingNewest(64))
        monitor = monitorsNetwork ? NWPathMonitor() : nil
        if let monitor {
            monitor.pathUpdateHandler = { [weak self] path in self?.networkChanged(path.status == .satisfied) }
            monitor.start(queue: DispatchQueue(label: "dev.openhuman.mail.reachability"))
        }
    }

    deinit { stop() }

    public static func event(for phase: ScenePhase) -> SystemEvent? {
        switch phase {
        case .active: .didBecomeActive
        case .inactive: .didResignActive
        case .background: .didEnterBackground
        @unknown default: nil
        }
    }

    public func scenePhaseChanged(to phase: ScenePhase) {
        if let event = Self.event(for: phase) { continuation.yield(event) }
    }

    func networkChanged(_ isReachable: Bool) {
        let changed = reachable.withLock { last in
            defer { last = isReachable }
            return last != isReachable
        }
        if changed { continuation.yield(.networkReachable(isReachable)) }
    }

    public func stop() {
        monitor?.cancel()
        continuation.finish()
    }
}
