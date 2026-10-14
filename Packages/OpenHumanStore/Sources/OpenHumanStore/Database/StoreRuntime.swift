import Dispatch
import Foundation
import GRDB
import OpenHumanCore
import Synchronization
#if canImport(Darwin)
import Darwin
import notify
#endif

struct MaintenanceStep: Sendable {
    var cursor: String?
    var done: Bool
}
typealias MaintenanceHandler = @Sendable (Database, String?) throws -> MaintenanceStep

final class StoreRuntime: Sendable {
    private struct State {
        var corrupt = false
        var lastWriteAt: Date?
        var lastCheckpointAt: Date?
        var postPending = false
        var lastPostAt: ContinuousClock.Instant?
        var posts = 0
        var monitor: ExternalChangeMonitor?
        var handlers: [String: MaintenanceHandler] = [:]
    }
    private let state = Mutex(State())
    let notificationName: String
    private let post: @Sendable (String) -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let runLater: @Sendable (Duration, @escaping @Sendable () -> Void) -> Void

    init(notificationName: String = OHIdentifiers.storeChangedNotification,
         post: @escaping @Sendable (String) -> Void = StoreRuntime.postDarwinNotification,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
         runLater: @escaping @Sendable (Duration, @escaping @Sendable () -> Void) -> Void = StoreRuntime.runOnUtilityQueue) {
        self.notificationName = notificationName
        self.post = post
        self.now = now
        self.runLater = runLater
    }

    static func postDarwinNotification(_ name: String) {
        #if canImport(Darwin)
        notify_post(name)
        #endif
    }

    static func runOnUtilityQueue(after delay: Duration, _ work: @escaping @Sendable () -> Void) {
        let nanoseconds = delay.components.seconds * 1_000_000_000 + delay.components.attoseconds / 1_000_000_000
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), execute: work)
    }

    var isCorrupt: Bool { state.withLock { $0.corrupt } }
    var monitor: ExternalChangeMonitor? {
        get { state.withLock { $0.monitor } }
        set { state.withLock { $0.monitor = newValue } }
    }
    var lastWriteAt: Date? { state.withLock { $0.lastWriteAt } }
    var lastCheckpointAt: Date? {
        get { state.withLock { $0.lastCheckpointAt } }
        set { state.withLock { $0.lastCheckpointAt = newValue } }
    }

    func markCorrupt() { state.withLock { $0.corrupt = true } }
    func noteWrite(at date: Date = Date()) { state.withLock { $0.lastWriteAt = date } }

    func handler(for task: String) -> MaintenanceHandler? { state.withLock { $0.handlers[task] } }
    func register(task: String, handler: @escaping MaintenanceHandler) {
        state.withLock { $0.handlers[task] = handler }
    }

    func noteError(_ error: Error) {
        guard let db = error as? DatabaseError else { return }
        if db.resultCode == .SQLITE_CORRUPT || db.resultCode == .SQLITE_NOTADB {
            state.withLock { $0.corrupt = true }
            Log(.store).error("database reports corruption (sqlite \(db.extendedResultCode.rawValue))")
        }
    }

    var postCount: Int { state.withLock { $0.posts } }

    var hasPendingPost: Bool { state.withLock { $0.postPending } }

    static let changePostDebounce: Duration = .milliseconds(50)

    // The first write after a quiet period posts at once: a one-shot CLI may exit within 50 ms and a deferred post would die with it
    func scheduleChangePost() {
        enum Action { case postNow, postLater(Duration), nothing }
        let action = state.withLock { s -> Action in
            if s.postPending { return .nothing }
            let instant = self.now()
            if let last = s.lastPostAt, instant - last < Self.changePostDebounce {
                s.postPending = true
                return .postLater(Self.changePostDebounce - (instant - last))
            }
            s.lastPostAt = instant
            s.posts += 1
            return .postNow
        }
        switch action {
        case .nothing: return
        case .postNow: post(notificationName)
        case let .postLater(delay): runLater(delay) { [self] in flushPendingPost() }
        }
    }

    func flushPendingPost() {
        let due = state.withLock { s -> Bool in
            guard s.postPending else { return false }
            s.postPending = false
            s.lastPostAt = self.now()
            s.posts += 1
            return true
        }
        if due { post(notificationName) }
    }
}
