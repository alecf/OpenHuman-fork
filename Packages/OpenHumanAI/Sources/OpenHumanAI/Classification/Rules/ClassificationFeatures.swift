import CryptoKit
import Foundation

public struct ClassificationFeatures: Sendable, Hashable, Codable {
    public var messageCount: Int
    public var userWroteLast: Bool
    public var userStartedConversation: Bool
    public var mostlyFromUser: Bool
    public var userWroteEarlier: Bool
    public var quotesUser: Bool
    public var replySubject: Bool
    public var acknowledgement: Bool
    public var sellerLanguage: Bool
    public var marketingFooter: Bool
    public var hasListUnsubscribe: Bool
    public var listIDPresent: Bool
    public var automatedSender: Bool
    public var bulkSenderShape: Bool
    public var recipientCount: Int
    public var userIsRecipient: Bool
    public var senderSharesUserDomain: Bool
    public var gmailImportant: Bool
    public var gmailCategory: String?
    public var hasAttachments: Bool
    public var hasCalendarInvite: Bool
    public var currentLabel: String?
    public var senderDomain: String?
    public var senderKey: String?
    public var listIDKey: String?

    public static func make(_ subject: RuleSubject, config: ClassificationConfig = .shipped, salt: Data? = nil)
        -> ClassificationFeatures {
        func params(_ id: String) -> RuleParams { config.defaultRule(id)?.params ?? .none }
        func value(_ id: RulePredicateID, _ rule: String = "") -> Bool {
            RuleEngine.value(of: RulePredicate(id), subject, params: params(rule))
        }
        let c = subject.conversation
        let address = c.signals.senderAddress
        let domain = address.split(separator: "@", omittingEmptySubsequences: false).count == 2
            ? address.split(separator: "@").last.map(String.init) : nil
        return ClassificationFeatures(
            messageCount: c.messages.count, userWroteLast: value(.userWroteLast),
            userStartedConversation: value(.userStartedConversation), mostlyFromUser: value(.mostlyFromUser),
            userWroteEarlier: value(.userWroteEarlier), quotesUser: value(.quotesUser),
            replySubject: AutoLabelRules.isReplySubject(c.subject,
                                                        prefixes: params(DefaultRules.acknowledgement).over(.shipped).replyPrefixes ?? []),
            acknowledgement: value(.acknowledgement, DefaultRules.acknowledgement),
            sellerLanguage: value(.sellerLanguage, DefaultRules.coldOutreach),
            marketingFooter: value(.marketingFooter, DefaultRules.bulkNeverRespond),
            hasListUnsubscribe: c.signals.hasListUnsubscribe, listIDPresent: subject.listID != nil,
            automatedSender: c.signals.automatedSender, bulkSenderShape: value(.bulkSender, DefaultRules.bulkNeverRespond),
            recipientCount: c.signals.recipientCount, userIsRecipient: c.signals.userIsRecipient,
            senderSharesUserDomain: c.signals.senderSharesUserDomain, gmailImportant: subject.gmailImportant,
            gmailCategory: subject.gmailCategory, hasAttachments: subject.hasAttachments,
            hasCalendarInvite: subject.hasCalendarInvite, currentLabel: subject.currentLabel?.rawValue,
            senderDomain: domain, senderKey: key(address, salt: salt), listIDKey: key(subject.listID, salt: salt))
    }

    public static func key(_ value: String?, salt: Data?) -> String? {
        guard let value = value?.lowercased(), !value.isEmpty, let salt, !salt.isEmpty else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: salt))
        return mac.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
