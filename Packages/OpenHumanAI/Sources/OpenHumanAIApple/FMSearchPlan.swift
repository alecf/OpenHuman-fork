import Foundation
import FoundationModels
import OpenHumanAI

@available(macOS 27, iOS 27, *)
@Generable
enum FMSearchTimeframe {
    case none, today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear
    case pastDays, pastWeeks, pastMonths, pastYears
    case month, year, sinceMonth, beforeMonth

    var value: SearchPlan.Timeframe {
        switch self {
        case .none: .none
        case .today: .today
        case .yesterday: .yesterday
        case .thisWeek: .thisWeek
        case .lastWeek: .lastWeek
        case .thisMonth: .thisMonth
        case .lastMonth: .lastMonth
        case .thisYear: .thisYear
        case .lastYear: .lastYear
        case .pastDays: .pastDays
        case .pastWeeks: .pastWeeks
        case .pastMonths: .pastMonths
        case .pastYears: .pastYears
        case .month: .month
        case .year: .year
        case .sinceMonth: .sinceMonth
        case .beforeMonth: .beforeMonth
        }
    }
}

@available(macOS 27, iOS 27, *)
@Generable
enum FMSearchAttachment {
    case notMentioned, any, pdf, document, spreadsheet, presentation, image, calendar

    var value: SearchPlan.AttachmentType? {
        switch self {
        case .notMentioned: nil
        case .any: .any
        case .pdf: .pdf
        case .document: .document
        case .spreadsheet: .spreadsheet
        case .presentation: .presentation
        case .image: .image
        case .calendar: .calendar
        }
    }
}

@available(macOS 27, iOS 27, *)
@Generable
enum FMSearchMailbox {
    case any, inbox, sent, drafts, anywhere

    var value: SearchPlan.Mailbox {
        switch self {
        case .any: .any
        case .inbox: .inbox
        case .sent: .sent
        case .drafts: .drafts
        case .anywhere: .anywhere
        }
    }
}

@available(macOS 27, iOS 27, *)
@Generable
struct FMSearchPlan {
    @Guide(description: "Words that say what the mail is about, as the user wrote them; at most 6")
    var keywords: [String]
    @Guide(description: "Senders' names or addresses exactly as written; at most 3")
    var from: [String]
    @Guide(description: "Recipients' names or addresses exactly as written; at most 3")
    var to: [String]
    @Guide(description: "Only when the user mentioned a time")
    var timeframe: FMSearchTimeframe
    @Guide(description: "For pastDays, pastWeeks, pastMonths, pastYears; 0 when not used", .range(0...36))
    var count: Int
    @Guide(description: "1 to 12 for month, sinceMonth, beforeMonth; 0 when not used", .range(0...12))
    var month: Int
    @Guide(description: "The year the user wrote; 0 when not used", .range(0...2100))
    var year: Int
    var attachment: FMSearchAttachment
    @Guide(description: "True only when the user asked for unread mail")
    var unread: Bool
    @Guide(description: "True only when the user asked for starred mail")
    var starred: Bool
    var mailbox: FMSearchMailbox
    @Guide(description: "A label name as written, or empty")
    var label: String
    @Guide(description: "One short phrase saying what the mail is about, or empty")
    var topic: String
}

@available(macOS 27, iOS 27, *)
extension FMSearchPlan {
    var json: Data {
        var object: [String: Any] = [
            "keywords": keywords, "from": from, "to": to, "timeframe": timeframe.value.rawValue,
            "mailbox": mailbox.value.rawValue,
        ]
        if count > 0 { object["count"] = count }
        if month > 0 { object["month"] = month }
        if year > 0 { object["year"] = year }
        if let attachment = attachment.value { object["attachment"] = attachment.rawValue }
        if unread { object["unread"] = true }
        if starred { object["starred"] = true }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { object["label"] = label }
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty { object["topic"] = topic }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
