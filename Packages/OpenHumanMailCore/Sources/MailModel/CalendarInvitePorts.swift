import Foundation
import OpenHumanCore

public struct CalendarInviteQuery: Sendable, Hashable {
    public var uid: String
    public var title: String
    public var start: Date
    public var end: Date
    public var organizer: String?

    public init(uid: String, title: String, start: Date, end: Date, organizer: String? = nil) {
        self.uid = uid
        self.title = title
        self.start = start
        self.end = end
        self.organizer = organizer?.lowercased()
    }

    public static let startSlack: TimeInterval = 60

    public var window: (from: Date, to: Date) {
        (start.addingTimeInterval(-Self.startSlack), start.addingTimeInterval(Self.startSlack))
    }

    public func startsTogether(_ start: Date) -> Bool { abs(start.timeIntervalSince(self.start)) <= Self.startSlack }

    public func looksLike(title: String?, organizer: String?) -> Bool {
        let mine = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == mine else { return false }
        guard let organizer, let expected = self.organizer else { return true }
        return organizer.lowercased() == expected
    }

    public enum Pick<Candidate> {
        case found(Candidate)
        case missing
        case ambiguous
    }

    public func pick<Candidate>(_ candidates: [Candidate], start: (Candidate) -> Date, uid: (Candidate) -> String?,
                                looksLike: (Candidate) -> Bool) -> Pick<Candidate> {
        let timed = candidates.filter { startsTogether(start($0)) }
        let byUID = timed.filter { uid($0) == self.uid }
        if byUID.count > 1 { return .ambiguous }
        if let only = byUID.first { return .found(only) }
        let alike = timed.filter(looksLike)
        if alike.count > 1 { return .ambiguous }
        if let only = alike.first { return .found(only) }
        return .missing
    }

    public static var ambiguousRefusal: String {
        String(localized: "Mail found more than one event that could be this invitation. Answer it in your calendar.")
    }
}

extension CalendarProviding {
    public func invitedEvent(_ query: CalendarInviteQuery, wholeSeries: Bool) async throws -> CalendarEvent? {
        throw CalendarError.refused("This calendar can't find invitations from Mail. Answer it in your calendar.")
    }
}

extension CalendarEvent {
    public var seriesReference: CalendarEvent {
        guard let series = recurringEventID, !series.isEmpty else { return self }
        return CalendarEvent(id: series, title: title, start: start, end: end, isAllDay: isAllDay, timeZone: timeZone,
                             attendees: attendees, calendarName: calendarName, meetLink: meetLink,
                             organizerIsMe: organizerIsMe, account: account, location: location, notes: notes,
                             myResponse: myResponse, recurringEventID: nil)
    }
}
