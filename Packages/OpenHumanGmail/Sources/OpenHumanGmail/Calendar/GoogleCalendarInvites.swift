import Foundation

public struct GoogleInviteCandidate: Sendable, Hashable {
    public let event: GoogleCalendarEvent
    public let iCalUID: String?
    public let organizerEmail: String?

    public init(event: GoogleCalendarEvent, iCalUID: String?, organizerEmail: String?) {
        self.event = event
        self.iCalUID = iCalUID
        self.organizerEmail = organizerEmail
    }
}

struct WireInviteIdentityList: Decodable {
    struct Item: Decodable {
        struct Organizer: Decodable { var email: String? }
        var id: String?
        var iCalUID: String?
        var organizer: Organizer?
    }
    var items: [Item]?
}
