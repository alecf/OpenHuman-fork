import Foundation

public enum SnoozeState: Sendable, Hashable {
    case until(Date, stampCount: Int)
    case wakeTimeUnknown

    public var wakeAt: Date? {
        if case .until(let date, _) = self { return date }
        return nil
    }
}

public enum ReminderKind: String, Sendable, Hashable, Codable {
    case always
    case ifNoReply
}

public struct ReminderItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let thread: ThreadKey
    public let subject: String
    public let dueAt: Date
    public let kind: ReminderKind

    public init(id: String, thread: ThreadKey, subject: String, dueAt: Date, kind: ReminderKind) {
        self.id = id
        self.thread = thread
        self.subject = subject
        self.dueAt = dueAt
        self.kind = kind
    }

    public var notificationIdentifier: String { "reminder.\(id)" }
}

extension ReminderItem {
    public static let someday = Date(timeIntervalSince1970: 253_402_214_400)

    public static func isSomeday(_ date: Date) -> Bool { date.timeIntervalSince1970 >= 221_845_392_000 }

    public var isSomeday: Bool { Self.isSomeday(dueAt) }
}

public enum ScheduleKindName: String, Sendable, Hashable, Codable, CaseIterable {
    case snooze
    case sendLater = "send_later"
    case reminder
}
