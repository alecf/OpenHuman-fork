import Foundation
import MailModel
import OpenHumanCore

public enum QuickReplyExclusion: String, Equatable, Sendable, CaseIterable {
    case calendarInvite, promotionOrSocial, bulkSender, notInInbox, spamOrTrash, tooLong

    public struct Facts: Hashable, Sendable {
        public var newestHasCalendarInvite: Bool
        public var newestWasCut: Bool
        public var newestHasListUnsubscribe: Bool?
        public var categories: [GmailLabelID]?
        public var inInbox: Bool?
        public var inSpamOrTrash: Bool?

        public init(newestHasCalendarInvite: Bool = false, newestWasCut: Bool = false,
                    newestHasListUnsubscribe: Bool? = nil, categories: [GmailLabelID]? = nil, inInbox: Bool? = nil,
                    inSpamOrTrash: Bool? = nil) {
            self.newestHasCalendarInvite = newestHasCalendarInvite
            self.newestWasCut = newestWasCut
            self.newestHasListUnsubscribe = newestHasListUnsubscribe
            self.categories = categories
            self.inInbox = inInbox
            self.inSpamOrTrash = inSpamOrTrash
        }
    }

    static let excludedCategories: Set<String> = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"]

    public static func reason(_ facts: Facts) -> QuickReplyExclusion? {
        if facts.inSpamOrTrash == true { return .spamOrTrash }
        if facts.inInbox == false { return .notInInbox }
        if facts.newestHasCalendarInvite { return .calendarInvite }
        if facts.categories?.contains(where: { excludedCategories.contains($0.rawValue.uppercased()) }) == true {
            return .promotionOrSocial
        }
        if facts.newestHasListUnsubscribe == true { return .bulkSender }
        if facts.newestWasCut { return .tooLong }
        return nil
    }

    public var text: String {
        switch self {
        case .calendarInvite: String(localized: "No quick replies for calendar invitations")
        case .promotionOrSocial: String(localized: "No quick replies for Promotions or Social mail")
        case .bulkSender: String(localized: "No quick replies for mailing lists")
        case .notInInbox: String(localized: "No quick replies outside the Inbox")
        case .spamOrTrash: String(localized: "No quick replies in Spam or Trash")
        case .tooLong: String(localized: "Too long for quick replies")
        }
    }
}
