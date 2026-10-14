#if os(macOS)
import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanAI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

private let now = Date(timeIntervalSince1970: 1_797_200_000)
private let pageWidth = SettingsMetrics.windowWidth - SettingsMetrics.sidebarWidth - 1

@MainActor
@Suite(.serialized)
struct ImportanceAndLabelsLayoutTests {
    static func ruleSet() async -> ClassificationRuleSet {
        let set = ClassificationRuleSet(environment: nil, now: { now })
        await set.load()
        _ = await set.add(ClassificationRule(
            id: "user.list", title: "Newsletters from the very long example list name are News",
            when: .all([.fact(.listID, "contains", .text("weekly-digest.newsletters.example-company.com")),
                        .not(.fact(.userInvolved))]), then: .setLabel(.news)))
        _ = await set.setDefault(DefaultRules.bulkNeverRespond, params: RuleParams(massRecipients: 6))
        _ = await set.setDefault(DefaultRules.marketingNeverPitch, enabled: false)
        return set
    }

    static func tracking(_ set: ClassificationRuleSet) -> ClassificationTrackingModel {
        let decisions = [
            ClassificationDecision(id: 2, account: AccountID(1), thread: GmailThreadID("t1"), latestMessage: GmailMessageID("m1"),
                                   decidedAt: now, decidedBy: "rule", ruleID: "user.list", outputLabel: "news",
                                   appliedState: .written),
            ClassificationDecision(id: 1, account: AccountID(1), thread: GmailThreadID("t2"), latestMessage: GmailMessageID("m2"),
                                   decidedAt: now, decidedBy: "model", modelOutput: "Respond", outputLabel: nil,
                                   appliedState: .localOnly),
        ]
        let examples = [LabelledExample(id: "e1", account: AccountID(1), thread: GmailThreadID("t2"), createdAt: now,
                                        expected: "news", was: "respond")]
        return ClassificationTrackingModel(environment: nil, ruleSet: set, center: nil, decisions: decisions,
                                           examples: examples)
    }

    @Test(arguments: [ImportanceSettingsPage.Tab.rules, .categories, .tracking])
    func everyTabStaysInsideThePage(_ tab: ImportanceSettingsPage.Tab) async throws {
        let set = await Self.ruleSet()
        let env = AppEnvironment.fake(corpus: .rich(threadCount: 4, now: now), options: .init(remoteAck: .immediate),
                                      featureFlags: FeatureFlags())
        if tab == .rules {
            set.pendingDraft = ClassificationRule(id: "user.new", title: "Mail from ed@letters.example is News",
                                                  when: .all([.fact(.sender, "equals", .text("ed@letters.example"))]),
                                                  then: .setLabel(.news))
        }
        for theme in [ResolvedTheme.light, .dark] {
            let page = ImportanceSettingsPage(model: ImportanceSettingsModel(environment: env), ruleSet: set,
                                              tracking: Self.tracking(set), tab: tab)
            let view = page.environment(\.theme, theme)
                .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
            let hosting = NSHostingController(rootView: view)
            let fitted = hosting.sizeThatFits(in: CGSize(width: pageWidth, height: 20_000))
            #expect(fitted.width <= pageWidth + 0.5, "\(tab) (\(theme.appearance)) is \(fitted.width) wide")
            hosting.view.frame = CGRect(x: 0, y: 0, width: pageWidth, height: 2_400)
            hosting.view.layoutSubtreeIfNeeded()
            try snapshot(hosting.view, "importance-labels-\(tab.rawValue)-\(theme.appearance == .dark ? "dark" : "light")")
        }
    }

    @Test func theRulesTabListsTheNineDefaultsAndTheSortingSteps() async {
        let set = await Self.ruleSet()
        #expect(set.config.defaultRules.count == 9)
        #expect(set.config.defaultRules.first { $0.id == DefaultRules.bulkNeverRespond }?.edited == true)
        #expect(set.config.defaultRules.first { $0.id == DefaultRules.marketingNeverPitch }?.enabled == false)
        #expect(RulesTab.steps(modelLine: "model").map(\.0) == ["Your answer for a conversation", "Your rules", "Default rules",
                                                                "Saved results", "A label already in Gmail", "The model"])
        #expect(RuleWords.sentence(set.config.rules[0])
            == "When the List-Id contains weekly-digest.newsletters.example-company.com and not you're part of it → News")
    }

    @Test func theTrackingLinesSayWhoDecidedAndShowNoText() async {
        let set = await Self.ruleSet()
        let model = Self.tracking(set)
        #expect(model.line(model.decisions[0]) == "News · rule: Newsletters from the very long example list name are News")
        #expect(model.line(model.decisions[1]) == "No label · model said Respond")
        model.filter = .model
        #expect(model.shownDecisions.count == 1)
        #expect(ClassificationTrackingModel.exampleLine(model.examples[0]) == "News (was Respond) · correction")
    }

    private func snapshot(_ view: NSView, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"], !dir.isEmpty,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
