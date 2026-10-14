import Foundation
import MailModel

public enum EventsTabOffer: Equatable, Sendable {
    case add(name: String)
    case upgrade(SplitInfo)

    public static let splitName = "Events"
    public static let ruleText = "is:event"
    public static let oldRuleText = "has:invite"
    static let names = [splitName, "Event mail", "Events and invites"]

    public static func offer(for splits: [SplitInfo]) -> EventsTabOffer? {
        func rule(_ split: SplitInfo) -> String { split.ruleText.trimmingCharacters(in: .whitespaces).lowercased() }
        if splits.contains(where: { rule($0) == ruleText }) { return nil }
        if let old = splits.sorted(by: { $0.position < $1.position }).first(where: { rule($0) == oldRuleText }) {
            return .upgrade(old)
        }
        let taken = Set(splits.map { $0.name.lowercased() })
        guard let name = names.first(where: { !taken.contains($0.lowercased()) }) else { return nil }
        return .add(name: name)
    }

    public var explanation: String {
        switch self {
        case .add:
            "Add an Events tab for calendar invitations, calendar notices and event mail. It hides while it is empty."
        case .upgrade(let split):
            "Your \(split.name) tab only shows invitations whose message was downloaded. Let it show every calendar "
                + "invitation, calendar notice and event email."
        }
    }

    public var buttonTitle: String {
        switch self {
        case .add: "Add the Events tab"
        case .upgrade(let split): "Update \(split.name)"
        }
    }

    public var doneTitle: String {
        switch self {
        case .add(let name): "Added the \(name) tab"
        case .upgrade(let split): "\(split.name) now shows events"
        }
    }
}
