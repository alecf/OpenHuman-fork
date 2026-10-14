import Foundation
import MailModel
import OpenHumanAI

@MainActor
enum AskCalendarEvents {
    static let maxEvents = 20
    static let reservedPlaces = 10
    static let daysBack = 7
    static let daysAhead = 14
    // Never a Gmail id, so a citation of an event never opens a conversation
    static let keyPrefix = "calendar-event-"

    static let words: Set<String> = [
        "calendar", "meeting", "meetings", "meet", "event", "events", "schedule", "scheduled", "busy", "free",
        "available", "availability", "agenda", "appointment", "appointments", "call", "calls", "invite", "invitation",
        "tomorrow", "tonight", "morning", "afternoon", "evening",
    ]

    static func isAbout(_ question: String) -> Bool {
        let tokens = question.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return tokens.contains { words.contains($0) || AskCueWords.time.contains($0) }
    }

    static func candidates(provider: any CalendarProviding, now: Date, timeZone: TimeZone) async -> [AIMessageInput] {
        let calendar = CalendarDateMentions.calendar(timeZone)
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -daysBack, to: today),
              let to = calendar.date(byAdding: .day, value: daysAhead + 1, to: today),
              let events = try? await provider.events(from: from, to: to) else { return [] }
        let accountKey = provider.info.account.map { AICenter.policyKey(email: $0) }
        let closest = events.sorted { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
            .prefix(maxEvents).sorted { $0.start < $1.start }
        return closest.enumerated().map { index, event in
            AIMessageInput(messageKey: keyPrefix + "\(index + 1)", from: String(localized: "Your calendar"),
                           date: event.start, bodyText: text(of: event, timeZone: timeZone),
                           subject: event.title, accountKey: accountKey)
        }
    }

    static func text(of event: CalendarEvent, timeZone: TimeZone) -> String {
        let day = event.start.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).month(.abbreviated).day())
        let when = event.isAllDay ? day + ", all day"
            : day + ", " + CalendarSidebarModel.range(event.start, event.end, timeZone)
                + " (\(CalendarSidebarModel.city(timeZone)) time)"
        var parts = ["Calendar event: \(event.title).", "When: \(when)."]
        let people = event.attendees.map { person -> String in
            if let name = person.name, !name.isEmpty { return name }
            return person.email
        }
        if !people.isEmpty { parts.append("With: \(people.joined(separator: ", ")).") }
        if let name = event.calendarName, !name.isEmpty { parts.append("Calendar: \(name).") }
        if event.meetLink != nil { parts.append("Has a Google Meet link.") }
        return parts.joined(separator: " ")
    }

    static func merge(_ retrieval: AskRetrieval, events: [AIMessageInput]) -> AskRetrieval {
        guard !events.isEmpty else { return retrieval }
        let cap = AIPolicy.askInboxMaxCandidates
        let mailKept = min(retrieval.candidates.count, cap - min(events.count, reservedPlaces))
        let eventsKept = min(events.count, cap - mailKept)
        var out = retrieval
        out.candidates = Array(retrieval.candidates.prefix(mailKept)) + Array(events.prefix(eventsKept))
        let line = eventsKept == 1 ? String(localized: "1 calendar event")
                                   : String(localized: "\(eventsKept) calendar events")
        out.planLine = retrieval.planLine.isEmpty ? line : retrieval.planLine + " · " + line
        return out
    }
}
