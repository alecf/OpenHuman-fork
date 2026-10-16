import Foundation
import Network
import OpenHumanMailLive
import OpenHumanSync
import SwiftUI
import Synchronization

final class AppSystemEvents: StoppableSystemEvents {
    let events: AsyncStream<SystemEvent>
    private let continuation: AsyncStream<SystemEvent>.Continuation
    private let monitor: NWPathMonitor?
    private let reachable = Mutex(true)
    private let active = Mutex<Bool?>(nil)

    @MainActor
    init(scenes: ScenePhaseRelay = .shared, monitorsNetwork: Bool = true) {
        (events, continuation) = AsyncStream.makeStream(of: SystemEvent.self, bufferingPolicy: .bufferingNewest(64))
        monitor = monitorsNetwork ? NWPathMonitor() : nil
        if let monitor {
            monitor.pathUpdateHandler = { [weak self] path in self?.networkChanged(path.status == .satisfied) }
            monitor.start(queue: DispatchQueue(label: "dev.openhuman.mail.ios.reachability"))
        }
        scenes.add(self)
    }

    deinit { stop() }

    func scenePhaseChanged(_ phase: ScenePhase) {
        let isActive: Bool
        switch phase {
        case .active: isActive = true
        case .inactive, .background: isActive = false
        @unknown default: return
        }
        let changed = active.withLock { last in
            defer { last = isActive }
            return last != isActive
        }
        if changed { continuation.yield(isActive ? .didBecomeActive : .didResignActive) }
    }

    func networkChanged(_ isReachable: Bool) {
        let changed = reachable.withLock { last in
            defer { last = isReachable }
            return last != isReachable
        }
        if changed { continuation.yield(.networkReachable(isReachable)) }
    }

    func stop() {
        monitor?.cancel()
        continuation.finish()
    }
}

@MainActor
final class ScenePhaseRelay {
    static let shared = ScenePhaseRelay()

    private(set) var phase: ScenePhase?
    private var listeners: [Listener] = []

    private struct Listener {
        weak var events: AppSystemEvents?
    }

    func add(_ events: AppSystemEvents) {
        listeners.removeAll { $0.events == nil }
        listeners.append(Listener(events: events))
        if let phase { events.scenePhaseChanged(phase) }
    }

    func changed(to phase: ScenePhase) {
        self.phase = phase
        listeners.removeAll { $0.events == nil }
        for listener in listeners { listener.events?.scenePhaseChanged(phase) }
    }
}
