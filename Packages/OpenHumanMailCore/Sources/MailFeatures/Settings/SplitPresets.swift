import Foundation
import MailModel

public struct SplitPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let ruleText: String
    public let needsDomain: Bool

    public init(id: String, name: String, summary: String, ruleText: String, needsDomain: Bool = false) {
        self.id = id
        self.name = name
        self.summary = summary
        self.ruleText = ruleText
        self.needsDomain = needsDomain
    }
}

public enum SplitPresets {
    public static let githubRuleText = "from:@github.com"

    static let legacyRuleTexts: [String: [String]] = [
        "github": ["from:notifications@github.com"],
        "linear": ["from:notifications@linear.app"],
    ]

    public static func upgradedRuleText(for ruleText: String) -> String? {
        let key = ruleText.trimmingCharacters(in: .whitespaces).lowercased()
        for (id, olds) in legacyRuleTexts where olds.contains(where: { $0.lowercased() == key }) {
            return all.first { $0.id == id }?.ruleText
        }
        return nil
    }

    public static let all: [SplitPreset] = [
        SplitPreset(id: "events", name: EventsTabOffer.splitName,
                    summary: "Calendar invitations, calendar notices and event mail",
                    ruleText: EventsTabOffer.ruleText),
        app("asana", "Asana"),
        app("clickup", "ClickUp"),
        SplitPreset(id: "github", name: "GitHub", summary: "Mail from github.com",
                    ruleText: SplitPresets.githubRuleText),
        SplitPreset(id: "linear", name: "Linear", summary: "Mail from linear.app",
                    ruleText: "from:@linear.app"),
        app("notion", "Notion"),
        SplitPreset(id: "slack", name: "Slack notifications", summary: "Mail from Slack's two sending domains",
                    ruleText: "from:@slack.com OR from:@slack-mail.com"),
        newsletters,
    ]

    public static let newsletters = SplitPreset(
        id: "newsletters", name: "Newsletters (List-Unsubscribe)",
        summary: "Mailing lists (List-Id header) and Gmail's Promotions category; split rules cannot read List-Unsubscribe",
        ruleText: "list:. OR category:promotions")

    public static let newslettersTabName = "Newsletters"

    public static func newslettersTabName(for splits: [SplitInfo]) -> String? {
        let rule = newsletters.ruleText.lowercased()
        let taken = splits.contains {
            $0.ruleText.trimmingCharacters(in: .whitespaces).lowercased() == rule
                || $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(newslettersTabName) == .orderedSame
        }
        return taken ? nil : newslettersTabName
    }

    private static func app(_ id: String, _ name: String) -> SplitPreset {
        SplitPreset(id: id, name: name, summary: "Type the sender's domain after the @", ruleText: "from:@", needsDomain: true)
    }
}
