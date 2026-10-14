import Foundation

public enum RuleOrigin: String, Sendable, Hashable, Codable {
    case `default`, user, suggested, imported
}

public enum RuleValue: Sendable, Hashable, Codable {
    case text(String)
    case number(Int)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        }
    }

    public var text: String {
        switch self {
        case .text(let text): return text
        case .number(let number): return String(number)
        }
    }

    public var number: Int? {
        switch self {
        case .number(let number): return number
        case .text(let text): return Int(text.trimmingCharacters(in: .whitespaces))
        }
    }
}

public enum RulePredicateID: String, Sendable, Hashable, Codable, CaseIterable {
    case userWroteLast, userStartedConversation, mostlyFromUser, userWroteEarlier, userInvolved
    case quotesUser, isReply, acknowledgement, sellerLanguage, marketingFooter, bulkSender
    case automatedSender, hasListUnsubscribe, userIsRecipient, senderSharesUserDomain, gmailImportant
    case hasAttachments, hasCalendarInvite
    case recipientCount, messageCount
    case sender, listID, subjectContains, textContains, gmailLabel, gmailCategory, currentLabel
    case bulk

    public var readsText: Bool {
        switch self {
        case .quotesUser, .isReply, .acknowledgement, .sellerLanguage, .marketingFooter, .subjectContains,
             .textContains, .bulk:
            return true
        default:
            return false
        }
    }

    public var takesValue: Bool {
        switch self {
        case .recipientCount, .messageCount, .sender, .listID, .subjectContains, .textContains, .gmailLabel,
             .gmailCategory, .currentLabel:
            return true
        default:
            return false
        }
    }
}

public struct RulePredicate: Sendable, Hashable, Codable {
    public var fact: String
    public var op: String?
    public var value: RuleValue?

    public init(_ id: RulePredicateID, op: String? = nil, value: RuleValue? = nil) {
        self.fact = id.rawValue
        self.op = op
        self.value = value
    }

    public init(fact: String, op: String? = nil, value: RuleValue? = nil) {
        self.fact = fact
        self.op = op
        self.value = value
    }

    public var known: RulePredicateID? { RulePredicateID(rawValue: fact) }
}

public indirect enum RuleCondition: Sendable, Hashable, Codable {
    case all([RuleCondition])
    case any([RuleCondition])
    case not(RuleCondition)
    case predicate(RulePredicate)

    private enum Keys: String, CodingKey { case all, any, not, fact, op, value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let all = try container.decodeIfPresent([RuleCondition].self, forKey: .all) {
            self = .all(all)
        } else if let any = try container.decodeIfPresent([RuleCondition].self, forKey: .any) {
            self = .any(any)
        } else if let not = try container.decodeIfPresent(RuleCondition.self, forKey: .not) {
            self = .not(not)
        } else {
            self = .predicate(RulePredicate(fact: try container.decode(String.self, forKey: .fact),
                                            op: try container.decodeIfPresent(String.self, forKey: .op),
                                            value: try container.decodeIfPresent(RuleValue.self, forKey: .value)))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .all(let list): try container.encode(list, forKey: .all)
        case .any(let list): try container.encode(list, forKey: .any)
        case .not(let inner): try container.encode(inner, forKey: .not)
        case .predicate(let predicate):
            try container.encode(predicate.fact, forKey: .fact)
            try container.encodeIfPresent(predicate.op, forKey: .op)
            try container.encodeIfPresent(predicate.value, forKey: .value)
        }
    }

    public var predicates: [RulePredicate] {
        switch self {
        case .all(let list), .any(let list): return list.flatMap(\.predicates)
        case .not(let inner): return inner.predicates
        case .predicate(let predicate): return [predicate]
        }
    }

    public var isKnown: Bool { predicates.allSatisfy { $0.known != nil } }

    public static func fact(_ id: RulePredicateID, _ op: String? = nil, _ value: RuleValue? = nil) -> RuleCondition {
        .predicate(RulePredicate(id, op: op, value: value))
    }
}

public enum RuleAction: Sendable, Hashable, Codable {
    case setLabel(AutoLabelCategory?)
    case forbidLabels([AutoLabelCategory])
    case importance(String)
    case gmailFlag(String)
    case builtIn(String)
    case unknown(String)

    private enum Keys: String, CodingKey { case setLabel, forbidLabels, importance, gmailFlag, builtIn }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if container.contains(.setLabel) {
            if try container.decodeNil(forKey: .setLabel) {
                self = .setLabel(nil)
            } else {
                let id = try container.decode(String.self, forKey: .setLabel)
                guard let category = AutoLabelCategory(title: id) else {
                    self = .unknown("setLabel:\(id)")
                    return
                }
                self = .setLabel(category)
            }
        } else if let ids = try container.decodeIfPresent([String].self, forKey: .forbidLabels) {
            self = .forbidLabels(ids.compactMap { AutoLabelCategory(title: $0) })
        } else if let value = try container.decodeIfPresent(String.self, forKey: .importance) {
            self = .importance(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .gmailFlag) {
            self = .gmailFlag(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .builtIn) {
            self = .builtIn(value)
        } else {
            self = .unknown(container.allKeys.map(\.stringValue).sorted().joined(separator: ","))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .setLabel(let category):
            if let category { try container.encode(category.rawValue, forKey: .setLabel) } else {
                try container.encodeNil(forKey: .setLabel)
            }
        case .forbidLabels(let list): try container.encode(list.map(\.rawValue), forKey: .forbidLabels)
        case .importance(let value): try container.encode(value, forKey: .importance)
        case .gmailFlag(let value): try container.encode(value, forKey: .gmailFlag)
        case .builtIn(let value): try container.encode(value, forKey: .builtIn)
        case .unknown: break
        }
    }

    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

public struct RuleParams: Sendable, Hashable, Codable {
    public var maxWords: Int?
    public var acknowledgementPhrases: [String]?
    public var actionWords: [String]?
    public var sellerPhrases: [String]?
    public var callToActionPhrases: [String]?
    public var markers: [String]?
    public var alwaysBulkLocalParts: [String]?
    public var bulkLocalPartsOnSendingDomains: [String]?
    public var sendingSubdomains: [String]?
    public var massRecipients: Int?
    public var maxRecipients: Int?
    public var replyPrefixes: [String]?

    public init(maxWords: Int? = nil, acknowledgementPhrases: [String]? = nil, actionWords: [String]? = nil,
                sellerPhrases: [String]? = nil, callToActionPhrases: [String]? = nil, markers: [String]? = nil,
                alwaysBulkLocalParts: [String]? = nil, bulkLocalPartsOnSendingDomains: [String]? = nil,
                sendingSubdomains: [String]? = nil, massRecipients: Int? = nil, maxRecipients: Int? = nil,
                replyPrefixes: [String]? = nil) {
        self.maxWords = maxWords
        self.acknowledgementPhrases = acknowledgementPhrases
        self.actionWords = actionWords
        self.sellerPhrases = sellerPhrases
        self.callToActionPhrases = callToActionPhrases
        self.markers = markers
        self.alwaysBulkLocalParts = alwaysBulkLocalParts
        self.bulkLocalPartsOnSendingDomains = bulkLocalPartsOnSendingDomains
        self.sendingSubdomains = sendingSubdomains
        self.massRecipients = massRecipients
        self.maxRecipients = maxRecipients
        self.replyPrefixes = replyPrefixes
    }

    public static let none = RuleParams()

    public var isEmpty: Bool { self == .none }

    public static let shipped = RuleParams(
        maxWords: AutoLabelRules.maximumAcknowledgementWords,
        acknowledgementPhrases: AutoLabelRules.acknowledgementPhrases,
        actionWords: AutoLabelRules.actionWords.sorted(),
        sellerPhrases: AutoLabelRules.sellerPhrases, callToActionPhrases: AutoLabelRules.callToActionPhrases,
        markers: AutoLabelRules.marketingMarkers,
        alwaysBulkLocalParts: AutoLabelRules.alwaysBulkLocalParts.sorted(),
        bulkLocalPartsOnSendingDomains: AutoLabelRules.bulkLocalPartsOnSendingDomains.sorted(),
        sendingSubdomains: AutoLabelRules.sendingSubdomains.sorted(),
        massRecipients: AutoLabelRules.massRecipientCount,
        maxRecipients: AutoLabelRules.maximumColdOutreachRecipients,
        replyPrefixes: AutoLabelRules.replyPrefixes)

    public func over(_ fallback: RuleParams) -> RuleParams {
        RuleParams(maxWords: maxWords ?? fallback.maxWords,
                   acknowledgementPhrases: acknowledgementPhrases ?? fallback.acknowledgementPhrases,
                   actionWords: actionWords ?? fallback.actionWords,
                   sellerPhrases: sellerPhrases ?? fallback.sellerPhrases,
                   callToActionPhrases: callToActionPhrases ?? fallback.callToActionPhrases,
                   markers: markers ?? fallback.markers,
                   alwaysBulkLocalParts: alwaysBulkLocalParts ?? fallback.alwaysBulkLocalParts,
                   bulkLocalPartsOnSendingDomains: bulkLocalPartsOnSendingDomains ?? fallback.bulkLocalPartsOnSendingDomains,
                   sendingSubdomains: sendingSubdomains ?? fallback.sendingSubdomains,
                   massRecipients: massRecipients ?? fallback.massRecipients,
                   maxRecipients: maxRecipients ?? fallback.maxRecipients,
                   replyPrefixes: replyPrefixes ?? fallback.replyPrefixes)
    }
}

public struct ClassificationRule: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var origin: RuleOrigin
    public var title: String
    public var enabled: Bool
    public var account: String?
    public var when: RuleCondition
    public var then: RuleAction
    public var shippedVersion: Int?
    public var edited: Bool
    public var params: RuleParams?

    public init(id: String, origin: RuleOrigin = .user, title: String, enabled: Bool = true, account: String? = nil,
                when: RuleCondition, then: RuleAction, shippedVersion: Int? = nil, edited: Bool = false,
                params: RuleParams? = nil) {
        self.id = id
        self.origin = origin
        self.title = title
        self.enabled = enabled
        self.account = account
        self.when = when
        self.then = then
        self.shippedVersion = shippedVersion
        self.edited = edited
        self.params = params
    }

    private enum Keys: String, CodingKey { case id, origin, title, enabled, account, when, then, shippedVersion, edited, params }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        origin = (try? c.decode(RuleOrigin.self, forKey: .origin)) ?? .user
        title = (try c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        enabled = (try c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        account = try c.decodeIfPresent(String.self, forKey: .account)
        when = try c.decode(RuleCondition.self, forKey: .when)
        then = try c.decode(RuleAction.self, forKey: .then)
        shippedVersion = try c.decodeIfPresent(Int.self, forKey: .shippedVersion)
        edited = (try c.decodeIfPresent(Bool.self, forKey: .edited)) ?? false
        params = try c.decodeIfPresent(RuleParams.self, forKey: .params)
    }

    public var isKnown: Bool { when.isKnown && then.isKnown }

    public var isActive: Bool { enabled && isKnown }

    public var readsText: Bool { when.predicates.contains { $0.known?.readsText ?? false } }

    public static func newUserID() -> String { "user." + UUID().uuidString }
}
