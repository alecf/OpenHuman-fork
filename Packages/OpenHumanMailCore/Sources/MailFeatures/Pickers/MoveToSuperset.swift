import Foundation
import MailActions
import MailModel
import OpenHumanCore

public enum MovePlace: String, Sendable, Hashable, CaseIterable {
    case inbox, important, other

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .important: "Important"
        case .other: "Other"
        }
    }

    public var actionID: ActionID {
        switch self {
        case .inbox: .moveToInbox
        case .important: .moveToImportant
        case .other: .moveToOther
        }
    }
}

public struct MovePlaceOption: Sendable, Hashable {
    public let place: MovePlace
    public let disabledReason: String?

    public init(place: MovePlace, disabledReason: String? = nil) {
        self.place = place
        self.disabledReason = disabledReason
    }
}

public struct MoveOptions: Sendable, Hashable {
    public var places: [MovePlaceOption]
    public var splits: [SplitInfo]
    public var sender: SplitRuleChoice?
    public var recentLabelIDs: [Int64]

    public init(places: [MovePlaceOption] = [], splits: [SplitInfo] = [], sender: SplitRuleChoice? = nil,
                recentLabelIDs: [Int64] = []) {
        self.places = places
        self.splits = splits
        self.sender = sender
        self.recentLabelIDs = recentLabelIDs
    }
}

public enum MoveToSuperset {
    public static let ruleSplitReason = "This split is made by a rule, not a label"
    public static let oneConversationReason = "Works on one conversation at a time"
    public static let splitTag = "split"
    public static let recentLabelLimit = 5

    public static func places(targets: [ThreadKey],
                              availability: (ActionID) -> ActionAvailability) -> [MovePlaceOption] {
        MovePlace.allCases.compactMap { place in
            let available = availability(place.actionID)
            if available == .hidden { return nil }
            if place != .inbox, targets.count != 1 {
                return MovePlaceOption(place: place, disabledReason: oneConversationReason)
            }
            if case .disabled(let reason) = available {
                return MovePlaceOption(place: place, disabledReason: reason.description)
            }
            return MovePlaceOption(place: place)
        }
    }

    public static func listedSplits(_ splits: [SplitInfo]) -> [SplitInfo] {
        AddToSplit.targets(splits)
    }

    public static func labelName(ofRule ruleText: String) -> String? {
        var parser = SplitRuleEvaluator.Parser(Array(ruleText))
        guard let node = parser.parseExpression(), parser.atEnd, case .term(let name, let value) = node,
              name == "label" else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func label(for split: SplitInfo, in labels: [LabelInfo]) -> LabelInfo? {
        guard let wanted = labelName(ofRule: split.ruleText)?.lowercased() else { return nil }
        return labels.first { $0.name.lowercased() == wanted || $0.labelID.rawValue.lowercased() == wanted }
    }

    static func recentFirst(_ labels: [LabelInfo], recent: [Int64]) -> [LabelInfo] {
        var seen = Set<Int64>()
        var front: [LabelInfo] = []
        for id in recent where front.count < recentLabelLimit && !seen.contains(id) {
            guard let label = labels.first(where: { $0.id == id }) else { continue }
            seen.insert(id)
            front.append(label)
        }
        return front + labels.filter { !seen.contains($0.id) }
    }

    static func noting(_ label: Int64, in recent: [Int64]) -> [Int64] {
        Array(([label] + recent.filter { $0 != label }).prefix(recentLabelLimit))
    }
}
