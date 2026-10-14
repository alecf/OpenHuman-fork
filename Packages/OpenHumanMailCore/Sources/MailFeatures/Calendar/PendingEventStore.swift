import Foundation
import MailModel
import Observation

public enum PendingEventKey: Hashable, Sendable {
    case thread(ThreadKey)
    case draft(UUID)
}

public struct PendingEvent: Sendable, Hashable {
    public var key: PendingEventKey
    public var draft: CalendarEventDraft
    public var thread: ThreadKey?
    public var titleIsSuggested: Bool
    public var updated: Date

    public init(key: PendingEventKey, draft: CalendarEventDraft, thread: ThreadKey?, titleIsSuggested: Bool = false,
                updated: Date = Date()) {
        self.key = key
        self.draft = draft
        self.thread = thread
        self.titleIsSuggested = titleIsSuggested
        self.updated = updated
    }
}

@MainActor @Observable
public final class PendingEventStore {
    public enum Feedback: String, Sendable, Hashable { case up, down }

    public struct ReturnRequest: Sendable, Hashable {
        public let id: Int
        public let thread: ThreadKey?
    }

    public static let capacity = 20

    public private(set) var events: [PendingEventKey: PendingEvent] = [:]
    public private(set) var active: PendingEventKey?
    public private(set) var returnRequest: ReturnRequest?
    public private(set) var feedbackCounts: [Feedback: Int] = [:]
    @ObservationIgnored public var now: @MainActor () -> Date = Date.init

    public init() {}

    public func pending(for key: PendingEventKey) -> PendingEvent? { events[key] }

    public var activeEvent: PendingEvent? { active.flatMap { events[$0] } }

    public func save(_ draft: CalendarEventDraft, for key: PendingEventKey, thread: ThreadKey?,
                     titleIsSuggested: Bool? = nil) {
        var event = events[key] ?? PendingEvent(key: key, draft: draft, thread: thread)
        if event.draft.title != draft.title, titleIsSuggested == nil { event.titleIsSuggested = false }
        event.draft = draft
        event.thread = thread
        if let titleIsSuggested { event.titleIsSuggested = titleIsSuggested }
        event.updated = now()
        events[key] = event
        active = key
        trim()
    }

    @discardableResult
    public func activate(_ key: PendingEventKey) -> Bool {
        guard events[key] != nil else { return false }
        active = key
        return true
    }

    public func deactivate(_ key: PendingEventKey) {
        if active == key { active = nil }
    }

    public func remove(_ key: PendingEventKey) {
        events[key] = nil
        if active == key { active = nil }
    }

    public func cancel(_ key: PendingEventKey) {
        let thread = events[key]?.thread
        remove(key)
        returnRequest = ReturnRequest(id: (returnRequest?.id ?? 0) + 1, thread: thread)
    }

    public func record(_ feedback: Feedback) {
        feedbackCounts[feedback, default: 0] += 1
    }

    private func trim() {
        guard events.count > Self.capacity else { return }
        let oldest = events.values.sorted { $0.updated < $1.updated }.prefix(events.count - Self.capacity)
        for event in oldest where event.key != active { events[event.key] = nil }
    }
}
