import Foundation
import MailModel
import Synchronization

public final class FakeSystemNotifier: SystemNotifying, Sendable {
    private struct State {
        var authorization: NotificationAuthorization
        var grantOnRequest: Bool
        var requests = 0
        var pending: [String: SystemNotification] = [:]
        var delivered: [String: SystemNotification] = [:]
        var log: [String] = []
    }
    private let state: Mutex<State>
    private let responder = Mutex<(@MainActor @Sendable (NotificationResponse) -> Void)?>(nil)

    public init(authorization: NotificationAuthorization = .notDetermined, grantOnRequest: Bool = true) {
        state = Mutex(State(authorization: authorization, grantOnRequest: grantOnRequest))
    }

    public func authorization() async -> NotificationAuthorization { state.withLock { $0.authorization } }

    public func requestAuthorization() async -> Bool {
        state.withLock { s in
            s.requests += 1
            if s.authorization == .notDetermined { s.authorization = s.grantOnRequest ? .authorized : .denied }
            return s.authorization == .authorized
        }
    }

    public func schedule(_ notification: SystemNotification) async {
        state.withLock { s in
            guard s.authorization == .authorized else { return }
            s.log.append(notification.identifier)
            if notification.deliverAt == nil {
                s.pending[notification.identifier] = nil
                s.delivered[notification.identifier] = notification
            } else {
                s.delivered[notification.identifier] = nil
                s.pending[notification.identifier] = notification
            }
        }
    }

    public func remove(identifiers: [String]) async {
        state.withLock { s in
            for id in identifiers {
                s.pending[id] = nil
                s.delivered[id] = nil
            }
        }
    }

    public func pendingIdentifiers() async -> [String] { state.withLock { Array($0.pending.keys).sorted() } }
    public func deliveredIdentifiers() async -> [String] { state.withLock { Array($0.delivered.keys).sorted() } }

    @MainActor public func setResponder(_ new: (@MainActor @Sendable (NotificationResponse) -> Void)?) {
        responder.withLock { $0 = new }
    }

    public var authorizationRequests: Int { state.withLock { $0.requests } }
    public var pending: [SystemNotification] { state.withLock { $0.pending.values.sorted { $0.identifier < $1.identifier } } }
    public var delivered: [SystemNotification] { state.withLock { $0.delivered.values.sorted { $0.identifier < $1.identifier } } }
    public var scheduleLog: [String] { state.withLock { $0.log } }

    public func deliverDue(identifier: String) {
        state.withLock { s in
            if let n = s.pending.removeValue(forKey: identifier) { s.delivered[identifier] = n }
        }
    }

    @MainActor public func respond(_ response: NotificationResponse) {
        let handler = responder.withLock { $0 }
        handler?(response)
    }
}

@MainActor
public final class FakeDockBadge: DockBadging {
    public private(set) var label = ""
    public private(set) var history: [String] = []

    public init() {}

    public func setBadge(_ label: String) {
        self.label = label
        history.append(label)
    }
}

@MainActor
public final class FakeLoginItem: LoginItemControlling {
    public var current: LoginItemStatus
    public private(set) var registerCalls = 0
    public private(set) var unregisterCalls = 0
    public private(set) var openedSettings = 0
    public var failure: (any Error)?
    public var statusAfterRegister: LoginItemStatus = .enabled

    public init(status: LoginItemStatus = .notRegistered) { current = status }

    public func status() -> LoginItemStatus { current }

    public func register() throws {
        registerCalls += 1
        if let failure { throw failure }
        current = statusAfterRegister
    }

    public func unregister() throws {
        unregisterCalls += 1
        if let failure { throw failure }
        current = .notRegistered
    }

    public func openSystemSettings() { openedSettings += 1 }
}

@MainActor
public final class FakeURLOpener: URLOpening {
    public private(set) var opened: [URL] = []
    public init() {}
    public func open(_ url: URL) { opened.append(url) }
}

@MainActor
public final class FakeMenuBarItem: MenuBarItemControlling {
    public private(set) var isShown = false
    public private(set) var count = ""
    public private(set) var countHistory: [String] = []
    public private(set) var showCalls = 0
    private var handler: (@MainActor (MenuBarCommand) -> Void)?
    public private(set) var threads: [MenuBarThreadItem] = []
    public private(set) var threadHistory: [[MenuBarThreadItem]] = []
    private var openThread: (@MainActor (ThreadKey) -> Void)?

    public init() {}

    public func setThreads(_ items: [MenuBarThreadItem], open: @escaping @MainActor (ThreadKey) -> Void) {
        threads = items
        threadHistory.append(items)
        openThread = open
    }

    public func chooseThread(_ key: ThreadKey) {
        guard isShown else { return }
        openThread?(key)
    }

    public func show(_ handler: @escaping @MainActor (MenuBarCommand) -> Void) {
        showCalls += 1
        isShown = true
        self.handler = handler
    }

    public func setCount(_ label: String) {
        count = label
        countHistory.append(label)
    }

    public func hide() {
        isShown = false
        handler = nil
        openThread = nil
        threads = []
    }

    public func choose(_ command: MenuBarCommand) {
        guard isShown else { return }
        handler?(command)
    }
}

@MainActor
public final class FakeGlobalHotkey: GlobalHotkeyRegistering {
    public private(set) var registered: GlobalHotkey?
    public private(set) var history: [GlobalHotkey] = []
    public private(set) var unregisterCalls = 0
    public var failure: GlobalHotkeyError?
    private var action: (@MainActor () -> Void)?

    public init() {}

    public func register(_ hotkey: GlobalHotkey, action: @escaping @MainActor () -> Void) throws {
        unregister()
        if let failure { throw failure }
        registered = hotkey
        history.append(hotkey)
        self.action = action
    }

    public func unregister() {
        if registered != nil { unregisterCalls += 1 }
        registered = nil
        action = nil
    }

    public func press() { action?() }
}

@MainActor
public final class FakeServicesRegistrar: ServicesRegistering {
    public private(set) var isRegistered = false
    public private(set) var registerCalls = 0
    public private(set) var unregisterCalls = 0
    private var handler: (@MainActor (ServiceRequest) -> Void)?

    public init() {}

    public func register(handler: @escaping @MainActor (ServiceRequest) -> Void) {
        registerCalls += 1
        isRegistered = true
        self.handler = handler
    }

    public func unregister() {
        if isRegistered { unregisterCalls += 1 }
        isRegistered = false
        handler = nil
    }

    @discardableResult
    public func deliver(_ request: ServiceRequest) -> Bool {
        guard isRegistered, let handler else { return false }
        handler(request)
        return true
    }
}

@MainActor
public final class FakeSystemTextSettings: SystemTextSettings {
    public private(set) var values: SystemTextValues
    private var observer: (@MainActor (SystemTextValues) -> Void)?

    public init(_ values: SystemTextValues = SystemTextValues()) { self.values = values }

    public func current() -> SystemTextValues { values }

    public func observe(_ body: @escaping @MainActor (SystemTextValues) -> Void) { observer = body }

    public func set(_ new: SystemTextValues) {
        values = new
        observer?(new)
    }
}
