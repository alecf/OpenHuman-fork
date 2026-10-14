import CryptoKit
import Foundation

public struct DefaultRuleState: Sendable, Hashable, Codable {
    public var id: String
    public var enabled: Bool
    public var params: RuleParams?

    public init(id: String, enabled: Bool, params: RuleParams? = nil) {
        self.id = id
        self.enabled = enabled
        self.params = params
    }
}

public struct ClassificationConfig: Sendable, Hashable, Codable {
    public static let format = "openhuman-classification-config"
    public static let formatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var rules: [ClassificationRule]
    public var defaults: [DefaultRuleState]

    public init(rules: [ClassificationRule] = [], defaults: [DefaultRuleState] = []) {
        self.format = Self.format
        self.formatVersion = Self.formatVersion
        self.rules = rules
        self.defaults = defaults
    }

    private enum Keys: String, CodingKey { case format, formatVersion, rules, defaults }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        format = (try c.decodeIfPresent(String.self, forKey: .format)) ?? Self.format
        formatVersion = (try c.decodeIfPresent(Int.self, forKey: .formatVersion)) ?? Self.formatVersion
        rules = (try c.decodeIfPresent([ClassificationRule].self, forKey: .rules)) ?? []
        defaults = (try c.decodeIfPresent([DefaultRuleState].self, forKey: .defaults)) ?? []
    }

    public static let shipped = ClassificationConfig()


    public var defaultRules: [ClassificationRule] {
        DefaultRules.v1.map { shipped in
            guard let state = defaults.first(where: { $0.id == shipped.id }) else { return shipped }
            var rule = shipped
            rule.enabled = state.enabled
            if let params = state.params, !params.isEmpty {
                rule.params = params.over(shipped.params ?? .none)
                rule.edited = true
            }
            return rule
        }
    }

    public func defaultRule(_ id: String) -> ClassificationRule? { defaultRules.first { $0.id == id } }

    public func settingDefault(_ id: String, enabled: Bool) -> ClassificationConfig {
        var copy = self
        if let index = copy.defaults.firstIndex(where: { $0.id == id }) {
            copy.defaults[index].enabled = enabled
        } else {
            copy.defaults.append(DefaultRuleState(id: id, enabled: enabled))
        }
        copy.normalizeDefaults()
        return copy
    }

    public func settingDefault(_ id: String, params: RuleParams?) -> ClassificationConfig {
        var copy = self
        let enabled = copy.defaults.first { $0.id == id }?.enabled ?? true
        copy.defaults.removeAll { $0.id == id }
        let shipped = DefaultRules.v1.first { $0.id == id }?.params ?? .none
        let edited = params.flatMap { $0.over(shipped) == shipped ? nil : $0 }
        copy.defaults.append(DefaultRuleState(id: id, enabled: enabled, params: edited))
        copy.normalizeDefaults()
        return copy
    }

    private mutating func normalizeDefaults() {
        let order = DefaultRules.v1.map(\.id)
        defaults = defaults.filter { !($0.enabled && ($0.params?.isEmpty ?? true)) || !order.contains($0.id) }
            .sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }


    public var digest: String {
        let canonical = ClassificationConfig(rules: rules, defaults: defaults)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(canonical)) ?? Data()
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var rulesModelID: String {
        if self == .shipped { return "rules@\(AutoLabelRules.version)" }
        return "rules@" + String(digest.dropFirst("sha256:".count).prefix(12))
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ json: String) throws -> ClassificationConfig {
        try JSONDecoder().decode(ClassificationConfig.self, from: Data(json.utf8))
    }
}

public enum DefaultRules {
    public static let version = 1

    public static let waiting = "default.waiting.user-wrote-last"
    public static let acknowledgement = "default.ack.no-label"
    public static let coldOutreach = "default.cold-outreach.pitch"
    public static let withYou = "default.with-you.no-bulk-labels"
    public static let bulkNeverRespond = "default.bulk.never-respond"
    public static let marketingNeverPitch = "default.marketing.never-pitch"
    public static let importanceGuard = "default.importance.bulk-needs-rule"
    public static let threadRejections = "default.rejections.thread"
    public static let senderRejections = "default.rejections.sender"

    public static let v1: [ClassificationRule] = [
        rule(waiting, "You wrote last: Waiting", .fact(.userWroteLast), .setLabel(.waiting)),
        rule(acknowledgement, "A short thank-you in a reply gets no label",
             .all([.fact(.isReply), .fact(.acknowledgement)]), .setLabel(nil),
             params: RuleParams(maxWords: RuleParams.shipped.maxWords,
                                acknowledgementPhrases: RuleParams.shipped.acknowledgementPhrases,
                                actionWords: RuleParams.shipped.actionWords,
                                replyPrefixes: RuleParams.shipped.replyPrefixes)),
        rule(coldOutreach, "First contact in seller language: Pitch",
             .all([.not(.fact(.isReply)), .not(.fact(.bulk)), .fact(.messageCount, "==", .number(1)),
                   .not(.fact(.senderSharesUserDomain)), .fact(.recipientCount, "<="), .fact(.sellerLanguage)]),
             .setLabel(.pitch),
             params: RuleParams(sellerPhrases: RuleParams.shipped.sellerPhrases,
                                callToActionPhrases: RuleParams.shipped.callToActionPhrases,
                                markers: RuleParams.shipped.markers,
                                alwaysBulkLocalParts: RuleParams.shipped.alwaysBulkLocalParts,
                                bulkLocalPartsOnSendingDomains: RuleParams.shipped.bulkLocalPartsOnSendingDomains,
                                sendingSubdomains: RuleParams.shipped.sendingSubdomains,
                                massRecipients: RuleParams.shipped.massRecipients,
                                maxRecipients: RuleParams.shipped.maxRecipients,
                                replyPrefixes: RuleParams.shipped.replyPrefixes)),
        rule(withYou, "A conversation you're part of is never Pitch, Marketing, News or Social",
             .fact(.userInvolved), .forbidLabels([.pitch, .marketing, .news, .social])),
        rule(bulkNeverRespond, "Bulk or automated mail is never Respond", .fact(.bulk), .forbidLabels([.respond]),
             params: RuleParams(markers: RuleParams.shipped.markers,
                                alwaysBulkLocalParts: RuleParams.shipped.alwaysBulkLocalParts,
                                bulkLocalPartsOnSendingDomains: RuleParams.shipped.bulkLocalPartsOnSendingDomains,
                                sendingSubdomains: RuleParams.shipped.sendingSubdomains,
                                massRecipients: RuleParams.shipped.massRecipients)),
        rule(marketingNeverPitch, "Marketing senders are never Pitch",
             .any([.fact(.bulkSender), .fact(.marketingFooter)]), .forbidLabels([.pitch]),
             params: RuleParams(markers: RuleParams.shipped.markers,
                                alwaysBulkLocalParts: RuleParams.shipped.alwaysBulkLocalParts,
                                bulkLocalPartsOnSendingDomains: RuleParams.shipped.bulkLocalPartsOnSendingDomains,
                                sendingSubdomains: RuleParams.shipped.sendingSubdomains)),
        rule(importanceGuard,
             "Gmail's Important mark doesn't count for bulk or list mail you're not part of; your own rules still do",
             .all([.fact(.bulk), .not(.fact(.userInvolved))]), .gmailFlag("needsRule")),
        rule(threadRejections, "A label you rejected never comes back to that conversation",
             .all([]), .builtIn("rejections.thread")),
        rule(senderRejections, "With \u{201C}Learn from what I do\u{201D}: a label you rejected never goes to that sender",
             .all([]), .builtIn("rejections.sender")),
    ]

    public static func summary(_ id: String) -> String {
        switch id {
        case waiting: return "The newest message is yours, so the conversation waits on the other side. No model call."
        case acknowledgement: return "A reply of a few words with thanks and no request needs nothing from you. No model call."
        case coldOutreach: return "A first message from outside, to a few people, with a sentence about their offer and a call to action. No model call."
        case withYou: return "When you started it, wrote most of it, wrote earlier or are quoted, the model can't choose a bulk category."
        case bulkNeverRespond: return "List-Unsubscribe, a no-reply or bulk sender, a marketing footer, many recipients, or you not in To/Cc."
        case marketingNeverPitch: return "A bulk sender address or a marketing footer (View in browser, Unsubscribe) is never a cold pitch."
        case importanceGuard: return "Not active in this build: Gmail's Important mark works as before. The importance guard arrives in a later update."
        case threadRejections: return "\u{201C}Wrong label\u{201D}, or our label taken off in Gmail, keeps that label off the conversation."
        case senderRejections: return "Only while \u{201C}Learn from what I do\u{201D} is on (this page, under Importance)."
        default: return ""
        }
    }

    public static func isActiveInThisBuild(_ id: String) -> Bool { id != importanceGuard }

    public static func hasParams(_ id: String) -> Bool {
        v1.first { $0.id == id }?.params != nil
    }

    private static func rule(_ id: String, _ title: String, _ when: RuleCondition, _ then: RuleAction,
                             params: RuleParams? = nil) -> ClassificationRule {
        ClassificationRule(id: id, origin: .default, title: title, enabled: true, when: when, then: then,
                           shippedVersion: version, edited: false, params: params)
    }
}
