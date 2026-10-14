import Foundation
import MailModel
import OpenHumanCore

public struct SchedulingSlot: Sendable, Hashable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var length: TimeInterval { end.timeIntervalSince(start) }
}

public struct SchedulingMove: Sendable, Hashable {
    public let event: CalendarEvent
    public let to: SchedulingSlot
    public var notifies: [EmailAddress] { event.attendees }
}

public enum SchedulingOption: Sendable, Hashable {
    case today([SchedulingSlot])
    case nextDay(SchedulingSlot)
    case acceptAndMove([SchedulingMove])
    case accept
    case askForOtherTimes
}

public struct SchedulingWorkday: Sendable, Hashable {
    public var startHour: Int
    public var endHour: Int
    public var buffer: TimeInterval

    public init(startHour: Int = 9, endHour: Int = 18, buffer: TimeInterval = 0) {
        self.startHour = max(0, min(23, startHour))
        self.endHour = max(self.startHour + 1, min(24, endHour))
        self.buffer = max(0, buffer)
    }

    public var hours: Range<Int> { startHour..<endHour }
}

public enum SchedulingAlternatives {
    public static let todayCount = 2
    public static let longestTodayBlock: TimeInterval = 2 * 3_600
    public static let longestDayBlock: TimeInterval = 3 * 3_600
    static let step: TimeInterval = 30 * 60

    public static func gaps(on day: Date, busy: [CalendarBusyInterval], workday: SchedulingWorkday, calendar: Calendar,
                            notBefore: Date, length: TimeInterval) -> [SchedulingSlot] {
        guard let open = calendar.date(bySettingHour: workday.startHour, minute: 0, second: 0, of: day),
              let close = workday.endHour >= 24 ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
                                                : calendar.date(bySettingHour: workday.endHour, minute: 0, second: 0, of: day)
        else { return [] }
        var cursor = max(open, roundUp(notBefore, from: open))
        var out: [SchedulingSlot] = []
        let blocks = busy.map { CalendarBusyInterval(start: $0.start.addingTimeInterval(-workday.buffer),
                                                     end: $0.end.addingTimeInterval(workday.buffer)) }
            .sorted { $0.start < $1.start }
        for block in blocks where block.end > cursor && block.start < close {
            if block.start > cursor, block.start.timeIntervalSince(cursor) >= length {
                out.append(SchedulingSlot(start: cursor, end: min(block.start, close)))
            }
            cursor = max(cursor, roundUp(block.end, from: open))
        }
        if cursor < close, close.timeIntervalSince(cursor) >= length { out.append(SchedulingSlot(start: cursor, end: close)) }
        return out
    }

    public static func today(now: Date, busy: [CalendarBusyInterval], workday: SchedulingWorkday, calendar: Calendar,
                             length: TimeInterval) -> [SchedulingSlot] {
        guard isWorkingDay(now, calendar: calendar) else { return [] }
        let free = gaps(on: calendar.startOfDay(for: now), busy: busy, workday: workday, calendar: calendar,
                        notBefore: now, length: length)
        return free.prefix(todayCount).map { gap in
            gap.length >= 2 * length
                ? SchedulingSlot(start: gap.start, end: gap.start.addingTimeInterval(min(gap.length, longestTodayBlock)))
                : SchedulingSlot(start: gap.start, end: gap.start.addingTimeInterval(length))
        }
    }

    public static func nextWorkingDay(after day: Date, calendar: Calendar) -> Date {
        var next = calendar.startOfDay(for: day)
        for _ in 0..<7 {
            next = calendar.date(byAdding: .day, value: 1, to: next) ?? next.addingTimeInterval(86_400)
            if isWorkingDay(next, calendar: calendar) { return next }
        }
        return next
    }

    public static func isWorkingDay(_ date: Date, calendar: Calendar) -> Bool { !calendar.isDateInWeekend(date) }

    public static func dayBlock(_ day: Date, now: Date, busy: [CalendarBusyInterval], workday: SchedulingWorkday,
                                calendar: Calendar, length: TimeInterval) -> SchedulingSlot? {
        let free = gaps(on: day, busy: busy, workday: workday, calendar: calendar, notBefore: max(now, day), length: length)
        guard let best = free.max(by: { $0.length < $1.length }) else { return nil }
        return SchedulingSlot(start: best.start, end: best.start.addingTimeInterval(min(best.length, longestDayBlock)))
    }

    public static func conflicts(_ proposal: SchedulingProposal, events: [CalendarEvent]) -> [CalendarEvent] {
        events.filter { !$0.isAllDay && $0.overlaps(from: proposal.start, to: proposal.end) }
    }

    public static func moves(for conflicts: [CalendarEvent], proposal: SchedulingProposal, busy: [CalendarBusyInterval],
                             now: Date, workday: SchedulingWorkday, calendar: Calendar) -> [SchedulingMove]? {
        guard !conflicts.isEmpty, conflicts.allSatisfy(\.isMovableByMe) else { return nil }
        var taken = busy.filter { block in !conflicts.contains { $0.start <= block.start && $0.end >= block.end } }
        taken.append(CalendarBusyInterval(start: proposal.start, end: proposal.end))
        var out: [SchedulingMove] = []
        for event in conflicts.sorted(by: { $0.start < $1.start }) {
            let length = event.end.timeIntervalSince(event.start)
            let day = calendar.startOfDay(for: proposal.start)
            let candidates = [day, nextWorkingDay(after: day, calendar: calendar)]
            var found: SchedulingSlot?
            for candidate in candidates where found == nil {
                found = gaps(on: candidate, busy: taken, workday: workday, calendar: calendar, notBefore: max(now, candidate),
                             length: length).first.map { SchedulingSlot(start: $0.start, end: $0.start.addingTimeInterval(length)) }
            }
            guard let slot = found else { return nil }
            taken.append(CalendarBusyInterval(start: slot.start, end: slot.end))
            out.append(SchedulingMove(event: event, to: slot))
        }
        return out
    }

    static func roundUp(_ date: Date, from origin: Date) -> Date {
        let offset = date.timeIntervalSince(origin)
        guard offset > 0 else { return date }
        let steps = (offset / step).rounded(.up)
        return origin.addingTimeInterval(steps * step)
    }
}
