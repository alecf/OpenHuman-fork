import Foundation
import MailModel

public enum CalendarCardMode: Sendable, Hashable {
    case detail, form, legacyEdit

    public static let contentFields: [CalendarFormField] = [.title, .time, .timeZone, .location, .meet, .notes, .repeats]

    public static func make(_ card: CalendarEventCard, userAskedToEdit: Bool) -> CalendarCardMode {
        if card.pendingMove != nil { return card.form != nil ? .form : .legacyEdit }
        if card.form != nil {
            if userAskedToEdit { return .form }
            return contentFields.contains { card.rights.access($0) == .editable } ? .form : .detail
        }
        return card.canMove || card.canEditDetails ? .legacyEdit : .detail
    }

    public static func offersEdit(_ card: CalendarEventCard, mode: CalendarCardMode) -> Bool {
        mode == .detail && card.form != nil && card.rights.hasAnyEditable
    }

    public static func width(available: Double) -> Double {
        min(max(available, 320), 440)
    }

    public static let rsvpOrder: [CalendarResponse] = [.accepted, .tentative, .declined]
}
