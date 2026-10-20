import Foundation
import FoundationModels
import OpenHumanAI

@available(macOS 27, iOS 27, *)
@Generable
enum FMTriageCategory {
    case needsReply, fyi, newsletter, notification, receipt, calendar, personal, other

    var category: TriageCategory {
        switch self {
        case .needsReply: return .needsReply
        case .fyi: return .fyi
        case .newsletter: return .newsletter
        case .notification: return .notification
        case .receipt: return .receipt
        case .calendar: return .calendar
        case .personal: return .personal
        case .other: return .other
        }
    }
}

@available(macOS 27, iOS 27, *)
@Generable
struct FMTriage {
    @Guide(description: "The best matching category")
    var category: FMTriageCategory
    @Guide(description: "0 ignore, 1 low, 2 normal, 3 urgent", .range(0...3))
    var priority: Int
    @Guide(description: "At most 15 words")
    var reason: String

    var result: TriageResult { TriageResult(category: category.category, priority: priority, reason: reason) }
}

@available(macOS 27, iOS 27, *)
@Generable
enum FMAutoLabelCategory {
    case other, meeting, invoice, travel, news, marketing, social, pitch, respond

    var category: AutoLabelCategory? {
        switch self {
        case .respond: return .respond
        case .meeting: return .meeting
        case .invoice: return .invoice
        case .travel: return .travel
        case .pitch: return .pitch
        case .social: return .social
        case .news: return .news
        case .marketing: return .marketing
        case .other: return nil
        }
    }
}

@available(macOS 27, iOS 27, *)
@Generable
struct FMAutoLabel {
    @Guide(description: "The one auto label that clearly fits, or other when unsure")
    var category: FMAutoLabelCategory
}

@available(macOS 27, iOS 27, *)
@Generable
struct FMReplyOption {
    @Guide(description: "At most 4 words")
    var label: String
    var body: String
}

@available(macOS 27, iOS 27, *)
@Generable
struct FMReplyOptions {
    @Guide(.count(3))
    var options: [FMReplyOption]
}

@available(macOS 27, iOS 27, *)
@Generable
struct FMFollowUp {
    @Guide(description: "true when the message asks a question, requests something, proposes a meeting or waits on a decision")
    var needsFollowUp: Bool
    @Guide(description: "At most 12 words")
    var reason: String
    @Guide(description: "Days until an answer is due when the message names a date, else 0", .range(0...14))
    var suggestedDays: Int
}

@available(macOS 27, iOS 27, *)
extension FMFollowUp {
    var json: Data {
        let days: Any = suggestedDays > 0 ? suggestedDays : NSNull()
        let object: [String: Any] = ["needsFollowUp": needsFollowUp, "reason": reason, "suggestedDays": days]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

@available(macOS 27, iOS 27, *)
extension FMTriage {
    var json: Data {
        let object: [String: Any] = ["category": category.category.rawValue, "priority": priority, "reason": reason]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

@available(macOS 27, iOS 27, *)
extension FMReplyOptions {
    var json: Data {
        let object: [String: Any] = ["options": options.map { ["label": $0.label, "body": $0.body] }]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
