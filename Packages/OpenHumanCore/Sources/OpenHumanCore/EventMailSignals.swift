import Foundation

public enum EventMailSignals {
    public static let calendarSenders: Set<String> = ["calendar-notification@google.com"]

    public static let invitationSubjectPrefixes = ["invitation:", "updated invitation:", "canceled event:"]

    public static let platformDomains = ["lu.ma", "luma-mail.com", "eventbrite.com", "meetup.com", "partiful.com"]

    public static let subjectPhrases = ["you are invited", "you're invited", "you\u{2019}re invited", "rsvp", "join us",
                                        "webinar"]

    public static let autoLabelCategory = "Meeting"

    public static var labelNames: [String] {
        [OHGmailLabels.autoLabel(autoLabelCategory), OHGmailLabels.superhumanAutoLabelPrefix + autoLabelCategory]
            .compactMap { $0 }
    }

    public static func headersSuggestEvent(fromEmail: String?, subject: String?) -> Bool {
        let from = fromEmail?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let subject = normalizedSubject(subject)
        if isCalendarSender(from) { return true }
        if hasInvitationPrefix(subject) { return true }
        if isPlatformSender(from) { return true }
        return subjectPhrases.contains { subject.contains($0) }
    }

    // Narrower than headersSuggestEvent on purpose: most event mail has no invite and every check costs a GET
    public static func shouldCheckForInvite(fromEmail: String?, subject: String?) -> Bool {
        let from = fromEmail?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        if isCalendarSender(from) { return true }
        return hasInvitationPrefix(normalizedSubject(subject))
    }

    public static let replyMarkers = ["", "re: ", "fwd: ", "fw: "]

    public static func hasInvitationPrefix(_ subject: String) -> Bool {
        replyMarkers.contains { marker in invitationSubjectPrefixes.contains { subject.hasPrefix(marker + $0) } }
    }

    public static func isCalendarSender(_ email: String?) -> Bool {
        guard let email else { return false }
        return calendarSenders.contains(email.lowercased().trimmingCharacters(in: .whitespaces))
    }

    public static func isPlatformSender(_ email: String?) -> Bool {
        guard let email, let at = email.lastIndex(of: "@") else { return false }
        let domain = email[email.index(after: at)...].lowercased()
        return platformDomains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    public static func normalizedSubject(_ subject: String?) -> String {
        String((subject ?? "").lowercased().drop { $0 == " " })
    }

    public static func isEventLabelName(_ name: String) -> Bool {
        labelNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}
