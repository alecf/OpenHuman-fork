import Foundation
import OpenHumanCore

public enum CalendarScope {
    public static let eventsReadonly = "https://www.googleapis.com/auth/calendar.events.readonly"
    public static let events = "https://www.googleapis.com/auth/calendar.events"
    public static let freebusy = "https://www.googleapis.com/auth/calendar.freebusy"
}

public enum GoogleCalendarAuth {
    public static let keychainService = OHIdentifiers.prefix + ".calendar.oauth.v1"
    public static let keychainLabel = "OpenHuman Mail (Google Calendar OAuth)"
}

public enum CalendarScopes {
    public static let request = (write: [CalendarScope.events, CalendarScope.freebusy],
                                 read: [CalendarScope.eventsReadonly, CalendarScope.freebusy])

    public static let all: Set<String> = Set(request.write + request.read)

    public static func requested(for mode: SafeMode) -> [String] {
        switch mode {
        case .normal: return request.write
        case .readOnly, .writeAllowlist: return request.read
        }
    }

    public static func beyondPinned(granted: [String], pinned: [String]) -> String? {
        let extra = Set(granted).subtracting(pinned).subtracting(tolerated(beyond: pinned)).sorted()
        return extra.isEmpty ? nil : extra.joined(separator: " ")
    }

    public static func tolerated(beyond requested: [String]) -> Set<String> {
        requested.contains(CalendarScope.events) ? OAuthScopes.identity.union([CalendarScope.eventsReadonly])
                                                 : OAuthScopes.identity
    }

    public static func check(granted: [String], requested: [String]) throws {
        let missing = OAuthScopes.missing(requested, in: granted)
        if !missing.isEmpty { throw OAuthError.insufficientScopes(missing: missing) }
        if let why = refusal(granted: granted, requested: requested) {
            Log(.oauth).error("calendar grant refused: \(why)")
            throw OAuthError.denied("calendar grant refused")
        }
    }

    public static func refusal(granted: [String], requested: [String]) -> String? {
        if let mail = granted.first(where: isMailScope) { return "a Gmail scope (\(mail)) in the calendar grant" }
        let extra = Set(granted).subtracting(requested).subtracting(tolerated(beyond: requested)).sorted()
        return extra.isEmpty ? nil : "scopes beyond the request (\(extra.joined(separator: " ")))"
    }

    public static func isUsable(_ granted: [String]) -> Bool {
        let readsEvents = granted.contains(CalendarScope.events) || granted.contains(CalendarScope.eventsReadonly)
        let onlyOurs = granted.allSatisfy { all.contains($0) || OAuthScopes.identity.contains($0) }
        return readsEvents && granted.contains(CalendarScope.freebusy) && onlyOurs
    }

    public static func allowsWrites(mode: SafeMode, granted: [String]) -> Bool {
        mode == .normal && granted.contains(CalendarScope.events) && isUsable(granted)
    }

    static func isMailScope(_ scope: String) -> Bool {
        scope == "https://mail.google.com/" || scope.hasPrefix("https://www.googleapis.com/auth/gmail.")
            || OAuthScopes.mailWrite.contains(scope)
    }
}
