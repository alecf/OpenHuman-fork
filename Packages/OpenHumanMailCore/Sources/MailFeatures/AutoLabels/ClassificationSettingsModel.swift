import Foundation
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore

public enum RuleWords {
    public static let editorPredicates: [RulePredicateID] = [
        .sender, .listID, .subjectContains, .textContains, .gmailLabel, .recipientCount, .messageCount,
        .hasListUnsubscribe, .automatedSender, .bulk, .userInvolved, .userWroteLast, .isReply, .userIsRecipient,
        .senderSharesUserDomain, .gmailImportant, .hasAttachments, .currentLabel,
    ]

    public static func title(_ id: RulePredicateID) -> String {
        switch id {
        case .userWroteLast: return "You wrote last"
        case .userStartedConversation: return "You started it"
        case .mostlyFromUser: return "Mostly from you"
        case .userWroteEarlier: return "You wrote earlier"
        case .userInvolved: return "You're part of it"
        case .quotesUser: return "It quotes you"
        case .isReply: return "It's a reply"
        case .acknowledgement: return "A short thank-you"
        case .sellerLanguage: return "Seller language"
        case .marketingFooter: return "A marketing footer"
        case .bulkSender: return "A bulk sender address"
        case .automatedSender: return "A no-reply sender"
        case .hasListUnsubscribe: return "Has List-Unsubscribe"
        case .userIsRecipient: return "You're in To or Cc"
        case .senderSharesUserDomain: return "The sender is a colleague"
        case .gmailImportant: return "Gmail marked it important"
        case .hasAttachments: return "Has attachments"
        case .hasCalendarInvite: return "Has an invitation"
        case .recipientCount: return "Recipients"
        case .messageCount: return "Messages"
        case .sender: return "The sender"
        case .listID: return "The List-Id"
        case .subjectContains: return "The subject contains"
        case .textContains: return "The preview contains"
        case .gmailLabel: return "It has the Gmail label"
        case .gmailCategory: return "Gmail's tab is"
        case .currentLabel: return "Its auto label is"
        case .bulk: return "Bulk or automated mail"
        }
    }

    public static func ops(_ id: RulePredicateID) -> [String] {
        switch id {
        case .sender: return ["equals", "domain", "contains"]
        case .listID: return ["contains", "equals"]
        case .recipientCount, .messageCount: return [">=", "<=", "=="]
        default: return []
        }
    }

    public static func opTitle(_ op: String) -> String {
        switch op {
        case "equals": return "is"
        case "domain": return "is at the domain"
        case "contains": return "contains"
        case ">=": return "at least"
        case "<=": return "at most"
        case "==": return "exactly"
        default: return op
        }
    }

    public static func phrase(_ condition: RuleCondition) -> String {
        switch condition {
        case .all(let list): return list.isEmpty ? "always" : list.map(phrase).joined(separator: " and ")
        case .any(let list): return list.isEmpty ? "never" : "(" + list.map(phrase).joined(separator: " or ") + ")"
        case .not(let inner): return "not " + phrase(inner).lowercased()
        case .predicate(let predicate):
            guard let id = predicate.known else { return "\u{201C}\(predicate.fact)\u{201D} (not known to this version)" }
            let title = Self.title(id)
            guard id.takesValue else { return title }
            let value = predicate.value?.text ?? ""
            if let op = predicate.op, !ops(id).isEmpty { return "\(title) \(opTitle(op)) \(value)" }
            return "\(title) \(value)"
        }
    }

    public static func action(_ action: RuleAction) -> String {
        switch action {
        case .setLabel(let category): return category?.title ?? "No label"
        case .forbidLabels(let list): return "Never " + list.map(\.title).joined(separator: ", ")
        case .importance(let value): return "Importance: \(value)"
        case .gmailFlag: return "Gmail's Important mark needs a rule"
        case .builtIn: return "Built in"
        case .unknown: return "An action this version doesn't know"
        }
    }

    public static func sentence(_ rule: ClassificationRule) -> String {
        "When " + phrase(rule.when).prefix(1).lowercased() + phrase(rule.when).dropFirst() + " \u{2192} " + action(rule.then)
    }

    public static func decision(_ row: ClassificationDecision, ruleTitle: (String) -> String?) -> String {
        let label = row.outputLabel.flatMap(AutoLabelCategory.init(title:))?.title ?? "No label"
        switch row.decidedBy {
        case "rule": return "\(label) · rule: \(row.ruleID.flatMap(ruleTitle) ?? row.ruleID ?? "a rule")"
        case "model":
            let said = row.modelOutput.flatMap(AutoLabelCategory.init(title:))?.title ?? "none"
            return said == label ? "\(label) · model" : "\(label) · model said \(said)"
        case "gmail_label": return "\(label) · label already in Gmail"
        default: return "\(label) · \(row.decidedBy)"
        }
    }

    public static func applied(_ state: DecisionAppliedState) -> String {
        switch state {
        case .pending: return "Writing"
        case .written: return "In Gmail"
        case .localOnly: return "This Mac"
        case .failed: return "Write failed"
        }
    }
}

@MainActor @Observable
public final class ClassificationTrackingModel {
    public enum Filter: String, CaseIterable, Sendable, Hashable {
        case all, rules, model, labels
        public var title: String {
            switch self {
            case .all: return "All"
            case .rules: return "Rules"
            case .model: return "Model"
            case .labels: return "Gmail labels"
            }
        }
    }

    public let logEnabled: StoredSetting<Bool>
    public let teach: StoredSetting<Bool>
    public let suggest: StoredSetting<Bool>
    public let keepText: StoredSetting<Bool>
    public let removesGmailFlag: StoredSetting<Bool>

    public private(set) var decisions: [ClassificationDecision] = []
    public private(set) var examples: [LabelledExample] = []
    public private(set) var subjects: [String: String] = [:]
    public var filter: Filter = .all
    public private(set) var message: String?
    public private(set) var hasLoaded = false

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private let ruleSet: ClassificationRuleSet
    @ObservationIgnored private let center: AutoLabelCenter?

    public convenience init(environment: AppEnvironment) {
        self.init(environment: environment, ruleSet: environment.classification, center: environment.autoLabels)
    }

    public init(environment: AppEnvironment?, ruleSet: ClassificationRuleSet, center: AutoLabelCenter?,
                decisions: [ClassificationDecision] = [], examples: [LabelledExample] = []) {
        self.environment = environment
        self.ruleSet = ruleSet
        self.center = center
        let port = environment?.settings
        logEnabled = StoredSetting(AppSettings.classificationDecisionLogEnabled, port: port)
        teach = StoredSetting(AppSettings.classificationTeachFromCorrections, port: port)
        suggest = StoredSetting(AppSettings.classificationSuggestRules, port: port)
        keepText = StoredSetting(AppSettings.classificationKeepInputText, port: port)
        removesGmailFlag = StoredSetting(AppSettings.classificationNotImportantRemovesGmailFlag, port: port)
        self.decisions = decisions
        self.examples = examples
        hasLoaded = !decisions.isEmpty || !examples.isEmpty
    }

    public func start() {
        for setting in [logEnabled, teach, suggest, keepText, removesGmailFlag] { setting.start() }
        Task { await reload() }
    }

    public func reload() async {
        if let center { await center.settleCorrections() }
        decisions = await center?.recentDecisions(limit: 200) ?? []
        examples = await ruleSet.examples(limit: 200)
        hasLoaded = true
        await lookUpSubjects()
    }

    public var shownDecisions: [ClassificationDecision] {
        switch filter {
        case .all: return decisions
        case .rules: return decisions.filter { $0.decidedBy == "rule" }
        case .model: return decisions.filter { $0.decidedBy == "model" }
        case .labels: return decisions.filter { $0.decidedBy == "gmail_label" }
        }
    }

    public static func subjectKey(_ account: AccountID?, _ thread: GmailThreadID?) -> String {
        "\(account?.rawValue ?? 0).\(thread?.rawValue ?? "")"
    }

    private func lookUpSubjects() async {
        guard let data = environment?.data else { return }
        var found: [String: String] = [:]
        let keys = decisions.prefix(60).map { ($0.account, $0.thread) } + examples.prefix(60).compactMap { example in
            example.account.flatMap { account in example.thread.map { (account, $0) } }
        }
        for (account, thread) in keys where found[Self.subjectKey(account, thread)] == nil {
            if let row = try? await data.localThread(account, gmailThreadID: thread) {
                found[Self.subjectKey(account, thread)] = row.subject
            }
        }
        subjects = found
    }

    public func subject(_ account: AccountID?, _ thread: GmailThreadID?) -> String? {
        subjects[Self.subjectKey(account, thread)]
    }

    public func ruleTitle(_ id: String) -> String? {
        ruleSet.config.rules.first { $0.id == id }?.title ?? ruleSet.config.defaultRule(id)?.title
    }

    public func line(_ row: ClassificationDecision) -> String {
        RuleWords.decision(row) { ruleTitle($0) }
    }

    public func clearLog() async {
        await center?.clearDecisionLog()
        decisions = []
        message = String(localized: "The decision log is empty.")
    }

    public func clearExamples() async {
        await ruleSet.clearExamples()
        examples = []
        message = String(localized: "Your corrections were cleared.")
    }

    public func delete(_ example: LabelledExample) async {
        await ruleSet.deleteExample(id: example.id)
        examples.removeAll { $0.id == example.id }
    }

    public static func exampleLine(_ example: LabelledExample) -> String {
        func word(_ id: String?) -> String {
            switch id {
            case nil, "none": return "No label"
            case "important": return "Important"
            case "not_important": return "Not important"
            case let other?: return AutoLabelCategory(title: other)?.title ?? other
            }
        }
        let source = example.source == "gmail_change" ? "changed in Gmail" : example.source
        return "\(word(example.expected)) (was \(word(example.was))) · \(source)"
    }
}

public struct RuleDraft: Sendable, Hashable {
    public struct Condition: Sendable, Hashable, Identifiable {
        public var id = UUID()
        public var predicate: RulePredicateID
        public var op: String
        public var value: String
        public var negated: Bool

        public init(predicate: RulePredicateID = .sender, op: String? = nil, value: String = "", negated: Bool = false) {
            self.predicate = predicate
            self.op = op ?? RuleWords.ops(predicate).first ?? ""
            self.value = value
            self.negated = negated
        }
    }

    public enum Action: Sendable, Hashable {
        case label(AutoLabelCategory)
        case noLabel
        case never(AutoLabelCategory)
    }

    public var id: String
    public var isNew: Bool
    public var title: String
    public var matchAll: Bool
    public var conditions: [Condition]
    public var action: Action
    public var account: String
    public var enabled: Bool

    public init(id: String = ClassificationRule.newUserID(), isNew: Bool = true, title: String = "",
                matchAll: Bool = true, conditions: [Condition] = [Condition()], action: Action = .label(.news),
                account: String = "", enabled: Bool = true) {
        self.id = id
        self.isNew = isNew
        self.title = title
        self.matchAll = matchAll
        self.conditions = conditions
        self.action = action
        self.account = account
        self.enabled = enabled
    }

    public init?(rule: ClassificationRule, isNew: Bool = false) {
        let list: [RuleCondition]
        var all = true
        switch rule.when {
        case .all(let items): list = items
        case .any(let items): list = items; all = false
        case .not, .predicate: list = [rule.when]
        }
        var conditions: [Condition] = []
        for item in list {
            var negated = false
            var inner = item
            if case .not(let wrapped) = item { negated = true; inner = wrapped }
            guard case .predicate(let predicate) = inner, let id = predicate.known else { return nil }
            conditions.append(Condition(predicate: id, op: predicate.op, value: predicate.value?.text ?? "", negated: negated))
        }
        let action: Action
        switch rule.then {
        case .setLabel(let category?): action = .label(category)
        case .setLabel(nil): action = .noLabel
        case .forbidLabels(let list) where list.count == 1: action = .never(list[0])
        default: return nil
        }
        self.init(id: rule.id, isNew: isNew, title: rule.title, matchAll: all, conditions: conditions, action: action,
                  account: rule.account ?? "", enabled: rule.enabled)
    }

    public var problem: String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Give the rule a name.") }
        if conditions.isEmpty { return String(localized: "Add at least one condition.") }
        for condition in conditions where condition.predicate.takesValue {
            let value = condition.value.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { return String(localized: "\(RuleWords.title(condition.predicate)): add a value.") }
            if [.recipientCount, .messageCount].contains(condition.predicate), Int(value) == nil {
                return String(localized: "\(RuleWords.title(condition.predicate)): use a whole number.")
            }
        }
        return nil
    }

    public func rule() -> ClassificationRule? {
        guard problem == nil else { return nil }
        let items: [RuleCondition] = conditions.map { c in
            let value = c.value.trimmingCharacters(in: .whitespaces)
            let typed: RuleValue? = !c.predicate.takesValue ? nil
                : [.recipientCount, .messageCount].contains(c.predicate) ? Int(value).map(RuleValue.number) : .text(value)
            let predicate = RuleCondition.predicate(RulePredicate(c.predicate, op: RuleWords.ops(c.predicate).isEmpty ? nil : c.op,
                                                                  value: typed))
            return c.negated ? .not(predicate) : predicate
        }
        let then: RuleAction
        switch action {
        case .label(let category): then = .setLabel(category)
        case .noLabel: then = .setLabel(nil)
        case .never(let category): then = .forbidLabels([category])
        }
        let account = account.trimmingCharacters(in: .whitespaces).lowercased()
        return ClassificationRule(id: id, origin: .user, title: title.trimmingCharacters(in: .whitespaces), enabled: enabled,
                                  account: account.isEmpty ? nil : account,
                                  when: matchAll ? .all(items) : .any(items), then: then)
    }
}

public struct DefaultParamsDraft: Sendable, Hashable {
    public struct Field: Sendable, Hashable, Identifiable {
        public var id: String { key }
        public var key: String
        public var title: String
        public var text: String
        public var isNumber: Bool
    }

    public var ruleID: String
    public var fields: [Field]

    public init(rule: ClassificationRule) {
        ruleID = rule.id
        let shipped = DefaultRules.v1.first { $0.id == rule.id }?.params ?? .none
        let current = (rule.params ?? .none).over(shipped)
        func list(_ key: String, _ title: String, _ value: [String]?, _ has: [String]?) -> Field? {
            has == nil ? nil : Field(key: key, title: title, text: (value ?? []).joined(separator: ", "), isNumber: false)
        }
        func number(_ key: String, _ title: String, _ value: Int?, _ has: Int?) -> Field? {
            has == nil ? nil : Field(key: key, title: title, text: value.map(String.init) ?? "", isNumber: true)
        }
        fields = [
            number("maxWords", "At most this many words", current.maxWords, shipped.maxWords),
            list("acknowledgementPhrases", "Thank-you phrases", current.acknowledgementPhrases, shipped.acknowledgementPhrases),
            list("actionWords", "Words that ask for something", current.actionWords, shipped.actionWords),
            list("sellerPhrases", "Seller phrases", current.sellerPhrases, shipped.sellerPhrases),
            list("callToActionPhrases", "Call-to-action phrases", current.callToActionPhrases, shipped.callToActionPhrases),
            list("markers", "Marketing footer words", current.markers, shipped.markers),
            list("alwaysBulkLocalParts", "Bulk sender names (any domain)", current.alwaysBulkLocalParts, shipped.alwaysBulkLocalParts),
            list("bulkLocalPartsOnSendingDomains", "Bulk sender names (sending subdomains)",
                 current.bulkLocalPartsOnSendingDomains, shipped.bulkLocalPartsOnSendingDomains),
            list("sendingSubdomains", "Sending subdomains", current.sendingSubdomains, shipped.sendingSubdomains),
            number("massRecipients", "Mass mail from this many recipients", current.massRecipients, shipped.massRecipients),
            number("maxRecipients", "Cold outreach to at most this many recipients", current.maxRecipients, shipped.maxRecipients),
            list("replyPrefixes", "Reply prefixes", current.replyPrefixes, shipped.replyPrefixes),
        ].compactMap { $0 }
    }

    public func params() -> RuleParams? {
        var p = RuleParams()
        for field in fields {
            let items = field.text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if field.isNumber {
                guard let n = Int(field.text.trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
                switch field.key {
                case "maxWords": p.maxWords = n
                case "massRecipients": p.massRecipients = n
                case "maxRecipients": p.maxRecipients = n
                default: break
                }
            } else {
                switch field.key {
                case "acknowledgementPhrases": p.acknowledgementPhrases = items
                case "actionWords": p.actionWords = items
                case "sellerPhrases": p.sellerPhrases = items
                case "callToActionPhrases": p.callToActionPhrases = items
                case "markers": p.markers = items
                case "alwaysBulkLocalParts": p.alwaysBulkLocalParts = items
                case "bulkLocalPartsOnSendingDomains": p.bulkLocalPartsOnSendingDomains = items
                case "sendingSubdomains": p.sendingSubdomains = items
                case "replyPrefixes": p.replyPrefixes = items
                default: break
                }
            }
        }
        return p
    }
}
