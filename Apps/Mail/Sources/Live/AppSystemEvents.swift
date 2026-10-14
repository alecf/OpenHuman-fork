import AppKit
import Foundation
import Network
import OpenHumanSync
import Synchronization

final class AppSystemEvents: SystemEventsSource {
    let events: AsyncStream<SystemEvent>
    private let continuation: AsyncStream<SystemEvent>.Continuation
    private let observers = Mutex<[(center: NotificationCenter, token: any NSObjectProtocol)]>([])
    private let monitor: NWPathMonitor?
    private let reachable = Mutex(true)

    @MainActor
    init(application: NotificationCenter = .default, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         monitorsNetwork: Bool = true) {
        (events, continuation) = AsyncStream.makeStream(of: SystemEvent.self, bufferingPolicy: .bufferingNewest(64))
        monitor = monitorsNetwork ? NWPathMonitor() : nil
        let continuation = self.continuation
        let subscriptions: [(NotificationCenter, Notification.Name, SystemEvent)] = [
            (workspace, NSWorkspace.didWakeNotification, .didWake),
            (application, NSApplication.didBecomeActiveNotification, .didBecomeActive),
            (application, NSApplication.didResignActiveNotification, .didResignActive),
        ]
        observers.withLock { list in
            for (center, name, event) in subscriptions {
                let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in continuation.yield(event) }
                list.append((center, token))
            }
        }
        if let monitor {
            monitor.pathUpdateHandler = { [weak self] path in self?.networkChanged(path.status == .satisfied) }
            monitor.start(queue: DispatchQueue(label: "dev.openhuman.mail.reachability"))
        }
    }

    deinit { stop() }

    func networkChanged(_ isReachable: Bool) {
        let changed = reachable.withLock { last in
            defer { last = isReachable }
            return last != isReachable
        }
        if changed { continuation.yield(.networkReachable(isReachable)) }
    }

    func stop() {
        monitor?.cancel()
        let list = observers.withLock { list in
            defer { list = [] }
            return list
        }
        for (center, token) in list { center.removeObserver(token) }
        continuation.finish()
    }
}
