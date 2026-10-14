import Foundation

public struct RuleSubject: Sendable, Hashable {
    public var conversation: AutoLabelConversation
    public var account: String?
    public var listID: String?
    public var gmailImportant: Bool
    public var gmailLabels: [String]
    public var gmailCategory: String?
    public var hasAttachments: Bool
    public var hasCalendarInvite: Bool
    public var currentLabel: AutoLabelCategory?

    public init(conversation: AutoLabelConversation, account: String? = nil, listID: String? = nil,
                gmailImportant: Bool = false, gmailLabels: [String] = [], gmailCategory: String? = nil,
                hasAttachments: Bool = false, hasCalendarInvite: Bool = false, currentLabel: AutoLabelCategory? = nil) {
        self.conversation = conversation
        self.account = account?.lowercased()
        self.listID = listID
        self.gmailImportant = gmailImportant
        self.gmailLabels = gmailLabels
        self.gmailCategory = gmailCategory?.lowercased()
        self.hasAttachments = hasAttachments
        self.hasCalendarInvite = hasCalendarInvite
        self.currentLabel = currentLabel
    }
}

public struct RuleMatch: Sendable, Hashable, Codable {
    public enum Effect: String, Sendable, Hashable, Codable {
        case decided
        case rejected
        case overridden
        case forbade
        case noEffect
    }

    public var ruleID: String
    public var effect: Effect
    public var categories: [AutoLabelCategory]

    public init(ruleID: String, effect: Effect, categories: [AutoLabelCategory] = []) {
        self.ruleID = ruleID
        self.effect = effect
        self.categories = categories
    }
}

public struct RuleVerdict: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        case decided(AutoLabelCategory?)
        case askModel
    }

    public var outcome: Outcome
    public var decidingRuleID: String?
    public var forbidden: Set<AutoLabelCategory>
    public var forbiddenBy: [String: [AutoLabelCategory]]
    public var matches: [RuleMatch]

    public var decided: AutoLabelCategory?? {
        if case .decided(let category) = outcome { return .some(category) }
        return nil
    }

    public func resolve(_ answer: AutoLabelCategory?) -> AutoLabelCategory? {
        AutoLabelRules.resolve(answer, forbidden: forbidden)
    }
}

public enum RuleEngine {
    public static func evaluate(_ config: ClassificationConfig, _ subject: RuleSubject,
                                rejected: Set<AutoLabelCategory> = [],
                                senderRejected: Set<AutoLabelCategory> = []) -> RuleVerdict {
        var verdict = RuleVerdict(outcome: .askModel, decidingRuleID: nil, forbidden: [], forbiddenBy: [:], matches: [])
        guard !subject.conversation.messages.isEmpty else { return verdict }
        let defaults = config.defaultRules
        let threadRejections = defaults.first { $0.id == DefaultRules.threadRejections }?.isActive ?? true
        let senderRejections = defaults.first { $0.id == DefaultRules.senderRejections }?.isActive ?? true
        let rejectedHere: Set<AutoLabelCategory> = threadRejections ? rejected : []
        var decided = false
        var userForbidden: Set<AutoLabelCategory> = []

        func forbid(_ categories: [AutoLabelCategory], by id: String) {
            guard !categories.isEmpty else { return }
            verdict.forbidden.formUnion(categories)
            verdict.forbiddenBy[id, default: []].append(contentsOf: categories)
        }

        for (isUser, rules) in [(true, config.rules), (false, defaults)] {
            for rule in rules where rule.isActive && applies(rule, to: subject) {
                if case .builtIn = rule.then { continue }
                guard matches(rule.when, subject, params: rule.params ?? .none) else { continue }
                switch rule.then {
                case .setLabel(let category):
                    if decided {
                        verdict.matches.append(RuleMatch(ruleID: rule.id, effect: .noEffect, categories: category.map { [$0] } ?? []))
                    } else if let category, !isUser, userForbidden.contains(category) {
                        verdict.matches.append(RuleMatch(ruleID: rule.id, effect: .overridden, categories: [category]))
                    } else if let category, rejectedHere.contains(category) {
                        decided = true
                        verdict.outcome = .decided(nil)
                        verdict.decidingRuleID = rule.id
                        verdict.matches.append(RuleMatch(ruleID: rule.id, effect: .rejected, categories: [category]))
                    } else {
                        decided = true
                        verdict.outcome = .decided(category)
                        verdict.decidingRuleID = rule.id
                        verdict.matches.append(RuleMatch(ruleID: rule.id, effect: .decided, categories: category.map { [$0] } ?? []))
                    }
                case .forbidLabels(let categories):
                    forbid(categories, by: rule.id)
                    if isUser { userForbidden.formUnion(categories) }
                    verdict.matches.append(RuleMatch(ruleID: rule.id, effect: .forbade, categories: categories))
                default:
                    verdict.matches.append(RuleMatch(ruleID: rule.id, effect: .noEffect))
                }
            }
        }
        forbid(AutoLabelCategory.allCases.filter(rejectedHere.contains), by: DefaultRules.threadRejections)
        if senderRejections {
            forbid(AutoLabelCategory.allCases.filter(senderRejected.contains), by: DefaultRules.senderRejections)
        }
        return verdict
    }

    static func applies(_ rule: ClassificationRule, to subject: RuleSubject) -> Bool {
        guard let account = rule.account?.lowercased(), !account.isEmpty else { return true }
        return subject.account == account
    }


    public static func matches(_ condition: RuleCondition, _ subject: RuleSubject, params: RuleParams = .none) -> Bool {
        switch condition {
        case .all(let list): return list.allSatisfy { matches($0, subject, params: params) }
        case .any(let list): return list.contains { matches($0, subject, params: params) }
        case .not(let inner): return !matches(inner, subject, params: params)
        case .predicate(let predicate): return value(of: predicate, subject, params: params)
        }
    }

    public static func value(of predicate: RulePredicate, _ subject: RuleSubject, params: RuleParams = .none) -> Bool {
        guard let id = predicate.known else { return false }
        let p = params.over(.shipped)
        let c = subject.conversation
        let messages = c.messages
        let latest = messages.last
        let signals = c.signals
        switch id {
        case .userWroteLast: return latest?.fromUser == true
        case .userStartedConversation: return messages.first?.fromUser == true
        case .mostlyFromUser: return messages.filter(\.fromUser).count * 2 > messages.count
        case .userWroteEarlier: return messages.dropLast().contains(where: \.fromUser)
        case .quotesUser: return quotesUser(c)
        case .userInvolved: return userInvolved(c)
        case .isReply:
            return userInvolved(c) || AutoLabelRules.isReplySubject(c.subject, prefixes: p.replyPrefixes ?? [])
        case .acknowledgement:
            guard let latest else { return false }
            return AutoLabelRules.isAcknowledgement(latest.text, maxWords: p.maxWords ?? 0,
                                                    phrases: p.acknowledgementPhrases ?? [],
                                                    actionWords: Set((p.actionWords ?? []).map { $0.lowercased() }))
        case .sellerLanguage:
            guard let latest else { return false }
            return AutoLabelRules.isSellerLanguage(latest.text, sellerPhrases: p.sellerPhrases ?? [],
                                                   callToActionPhrases: p.callToActionPhrases ?? [])
        case .marketingFooter:
            guard let latest else { return false }
            return AutoLabelRules.hasMarketingFooter(latest.text, markers: p.markers ?? [])
        case .bulkSender: return bulkSender(signals.senderAddress, p)
        case .automatedSender: return signals.automatedSender
        case .hasListUnsubscribe: return signals.hasListUnsubscribe
        case .userIsRecipient: return signals.userIsRecipient
        case .senderSharesUserDomain: return signals.senderSharesUserDomain
        case .gmailImportant: return subject.gmailImportant
        case .hasAttachments: return subject.hasAttachments
        case .hasCalendarInvite: return subject.hasCalendarInvite
        case .recipientCount:
            return compare(signals.recipientCount, predicate, fallback: p.maxRecipients, defaultOp: "<=")
        case .messageCount:
            return compare(messages.count, predicate, fallback: nil, defaultOp: "==")
        case .sender:
            let value = (predicate.value?.text ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            let address = signals.senderAddress
            guard !value.isEmpty, !address.isEmpty else { return false }
            switch (predicate.op ?? "equals").lowercased() {
            case "domain":
                let domain = address.split(separator: "@").last.map(String.init) ?? ""
                let wanted = value.hasPrefix("@") ? String(value.dropFirst()) : value
                return domain == wanted || domain.hasSuffix("." + wanted)
            case "contains": return address.contains(value)
            default: return address == value
            }
        case .listID:
            return textMatch(subject.listID, predicate, defaultOp: "contains")
        case .subjectContains:
            return textMatch(c.subject, predicate, defaultOp: "contains")
        case .textContains:
            return textMatch(latest?.text, predicate, defaultOp: "contains")
        case .gmailLabel:
            let value = (predicate.value?.text ?? "").lowercased()
            return !value.isEmpty && subject.gmailLabels.contains { $0.lowercased() == value }
        case .gmailCategory:
            let value = (predicate.value?.text ?? "").lowercased()
            return !value.isEmpty && subject.gmailCategory == value
        case .currentLabel:
            let value = predicate.value.flatMap { AutoLabelCategory(title: $0.text) }
            return value != nil && subject.currentLabel == value
        case .bulk:
            let marketing = bulkSender(signals.senderAddress, p)
                || (latest.map { AutoLabelRules.hasMarketingFooter($0.text, markers: p.markers ?? []) } ?? false)
            return marketing || signals.hasListUnsubscribe || signals.automatedSender
                || signals.recipientCount >= (p.massRecipients ?? AutoLabelRules.massRecipientCount)
                || !signals.userIsRecipient
        }
    }

    static func quotesUser(_ c: AutoLabelConversation) -> Bool {
        guard let latest = c.messages.last else { return false }
        return AutoLabelRules.quotesUser(latest.text, identities: c.userIdentities)
    }

    static func userInvolved(_ c: AutoLabelConversation) -> Bool {
        let m = c.messages
        return m.first?.fromUser == true || m.filter(\.fromUser).count * 2 > m.count
            || m.dropLast().contains(where: \.fromUser) || quotesUser(c)
    }

    static func bulkSender(_ address: String, _ p: RuleParams) -> Bool {
        AutoLabelRules.isBulkSender(address, alwaysBulk: Set((p.alwaysBulkLocalParts ?? []).map { $0.lowercased() }),
                                    onSendingDomains: Set((p.bulkLocalPartsOnSendingDomains ?? []).map { $0.lowercased() }),
                                    sendingSubdomains: Set((p.sendingSubdomains ?? []).map { $0.lowercased() }))
    }

    static func compare(_ actual: Int, _ predicate: RulePredicate, fallback: Int?, defaultOp: String) -> Bool {
        guard let target = predicate.value?.number ?? fallback else { return false }
        switch predicate.op ?? defaultOp {
        case ">=": return actual >= target
        case "<=": return actual <= target
        case ">": return actual > target
        case "<": return actual < target
        default: return actual == target
        }
    }

    static func textMatch(_ text: String?, _ predicate: RulePredicate, defaultOp: String) -> Bool {
        let value = (predicate.value?.text ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        guard let text = text?.lowercased(), !value.isEmpty else { return false }
        switch (predicate.op ?? defaultOp).lowercased() {
        case "equals": return text.trimmingCharacters(in: .whitespaces) == value
        default: return text.contains(value)
        }
    }
}
