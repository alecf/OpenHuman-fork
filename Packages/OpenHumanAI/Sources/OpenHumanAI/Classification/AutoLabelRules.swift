import Foundation

public struct AutoLabelConversation: Sendable, Hashable {
    public struct Message: Sendable, Hashable {
        public var fromUser: Bool
        public var text: String

        public init(fromUser: Bool, text: String) {
            self.fromUser = fromUser
            self.text = text
        }
    }

    public struct Signals: Sendable, Hashable {
        public var hasListUnsubscribe: Bool
        public var automatedSender: Bool
        public var recipientCount: Int
        public var userIsRecipient: Bool
        public var senderSharesUserDomain: Bool
        public var senderAddress: String

        public init(hasListUnsubscribe: Bool = false, automatedSender: Bool = false, recipientCount: Int = 0,
                    userIsRecipient: Bool = true, senderSharesUserDomain: Bool = false, senderAddress: String = "") {
            self.hasListUnsubscribe = hasListUnsubscribe
            self.automatedSender = automatedSender
            self.recipientCount = recipientCount
            self.userIsRecipient = userIsRecipient
            self.senderSharesUserDomain = senderSharesUserDomain
            self.senderAddress = senderAddress.lowercased()
        }
    }

    public var subject: String
    public var messages: [Message]
    public var userIdentities: Set<String>
    public var signals: Signals

    public init(subject: String, messages: [Message], userIdentities: Set<String>, signals: Signals = Signals()) {
        self.subject = subject
        self.messages = messages
        self.userIdentities = userIdentities
        self.signals = signals
    }
}

public enum AutoLabelRules {
    public static let version = 1

    public enum Reason: String, Sendable, Hashable, CaseIterable {
        case userWroteLast
        case acknowledgement
        case userStartedConversation
        case mostlyFromUser
        case replyToUser
        case quotesUser
        case bulkOrAutomated
        case marketingSender
        case coldOutreach
    }

    public enum Verdict: Sendable, Hashable {
        case decided(AutoLabelCategory?, Reason)
        case askModel(forbidden: Set<AutoLabelCategory>, reasons: [Reason])

        public var forbidden: Set<AutoLabelCategory> {
            if case .askModel(let forbidden, _) = self { return forbidden }
            return []
        }
    }

    public static let notForConversationsWithTheUser: Set<AutoLabelCategory> = [.pitch, .marketing, .news, .social]

    static let maximumAcknowledgementWords = 10
    public static let massRecipientCount = 10
    static let maximumColdOutreachRecipients = 3

    public static func evaluate(_ conversation: AutoLabelConversation) -> Verdict {
        guard let latest = conversation.messages.last else { return .askModel(forbidden: [], reasons: []) }
        if latest.fromUser { return .decided(.waiting, .userWroteLast) }
        var reasons: [Reason] = []
        if conversation.messages.first?.fromUser == true { reasons.append(.userStartedConversation) }
        if conversation.messages.filter(\.fromUser).count * 2 > conversation.messages.count {
            reasons.append(.mostlyFromUser)
        }
        if conversation.messages.dropLast().contains(where: \.fromUser) { reasons.append(.replyToUser) }
        if quotesUser(latest.text, identities: conversation.userIdentities) { reasons.append(.quotesUser) }
        let withUser = !reasons.isEmpty
        let isReply = withUser || isReplySubject(conversation.subject)
        if isReply, isAcknowledgement(latest.text) { return .decided(nil, .acknowledgement) }
        let signals = conversation.signals
        let marketing = isBulkSender(signals.senderAddress) || hasMarketingFooter(latest.text)
        let bulk = marketing || signals.hasListUnsubscribe || signals.automatedSender
            || signals.recipientCount >= massRecipientCount || !signals.userIsRecipient
        if !isReply, !bulk, conversation.messages.count == 1, !signals.senderSharesUserDomain,
           signals.recipientCount <= maximumColdOutreachRecipients, isSellerLanguage(latest.text) {
            return .decided(.pitch, .coldOutreach)
        }
        var forbidden: Set<AutoLabelCategory> = withUser ? notForConversationsWithTheUser : []
        if bulk {
            forbidden.insert(.respond)
            reasons.append(.bulkOrAutomated)
        }
        if marketing {
            forbidden.insert(.pitch)
            reasons.append(.marketingSender)
        }
        return .askModel(forbidden: forbidden, reasons: reasons)
    }

    public static func resolve(_ answer: AutoLabelCategory?, forbidden: Set<AutoLabelCategory>) -> AutoLabelCategory? {
        guard let answer, !forbidden.contains(answer) else { return nil }
        return answer
    }

    static func isReplySubject(_ subject: String) -> Bool {
        isReplySubject(subject, prefixes: replyPrefixes)
    }

    static let replyPrefixes = ["re:", "re :", "aw:", "sv:", "vs:", "antw:", "rif:", "réf:", "ref:"]

    static func isReplySubject(_ subject: String, prefixes: [String]) -> Bool {
        let text = subject.trimmingCharacters(in: .whitespaces).lowercased()
        return prefixes.contains { text.hasPrefix($0.lowercased()) }
    }

    static let quoteHeaderPatterns = [
        #"(?s)\bon\b.{0,240}?\bwrote\s*:"#,
        #"(?s)\bam\b.{0,240}?\bschrieb\b[^:\n]{0,160}:"#,
        #"(?s)\ble\b.{0,240}?\ba écrit\s*:"#,
        #"(?s)\bel\b.{0,240}?\bescribió\s*:"#,
        #"(?s)\bfrom:\s.{0,240}?\b(sent|date):"#,
    ]

    static let quotePatterns = quoteHeaderPatterns + [
        #"-{2,}\s*original message\s*-{2,}"#,
        #"-{2,}\s*forwarded message\s*-{2,}"#,
        #"(^|\n)\s*>"#,
    ]

    static func replyPart(_ text: String) -> String {
        var end = text.endIndex
        for pattern in quotePatterns {
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
               range.lowerBound < end {
                end = range.lowerBound
            }
        }
        return String(text[..<end])
    }

    static func quotesUser(_ text: String, identities: Set<String>) -> Bool {
        let usable = identities.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") || ($0.contains(" ") && $0.count >= 5) }
        guard !usable.isEmpty else { return false }
        for pattern in quoteHeaderPatterns {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive],
                                         range: searchStart..<text.endIndex) {
                let header = text[range].lowercased()
                if usable.contains(where: { header.contains($0) }) { return true }
                guard !range.isEmpty else { break }
                searchStart = range.upperBound
            }
        }
        return false
    }

    static let acknowledgementPhrases: [String] = [
        "thanks", "thank you", "thank u", "thx", "ty", "tysm", "many thanks", "much appreciated", "appreciate it",
        "appreciated", "congrats", "congratulations", "got it", "received", "noted", "will do", "sounds good",
        "cheers", "merci", "danke", "gracias", "grazie", "obrigado",
    ]

    static let actionWords: Set<String> = [
        "call", "meet", "meeting", "schedule", "invoice", "attached", "attachment", "send", "sign", "review",
        "pricing", "price", "quote", "demo", "available", "availability", "when", "please", "could", "can",
        "would", "partnership", "partner", "sponsor", "offer", "discount",
    ]

    static let alwaysBulkLocalParts: Set<String> = [
        "newsletter", "newsletters", "marketing", "noreply", "no-reply", "donotreply", "do-not-reply", "notifications",
        "notification", "updates", "digest", "promotions", "promo", "offers", "deals", "news",
    ]
    static let bulkLocalPartsOnSendingDomains: Set<String> = [
        "hello", "hi", "info", "team", "community", "contact", "support-bot", "mail", "email", "say", "hey",
    ]
    static let sendingSubdomains: Set<String> = [
        "send", "mail", "mailer", "mailing", "email", "em", "e", "news", "newsletter", "newsletters", "mg", "marketing",
        "updates", "info", "notify", "notifications", "comms", "m", "t", "go", "hello", "engage", "crm",
    ]

    public static func isBulkSender(_ address: String) -> Bool {
        isBulkSender(address, alwaysBulk: alwaysBulkLocalParts, onSendingDomains: bulkLocalPartsOnSendingDomains,
                     sendingSubdomains: sendingSubdomains)
    }

    static func isBulkSender(_ address: String, alwaysBulk: Set<String>, onSendingDomains: Set<String>,
                             sendingSubdomains: Set<String>) -> Bool {
        let parts = address.lowercased().split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let local = String(parts[0]).split(separator: "+").first.map(String.init) ?? ""
        if alwaysBulk.contains(local) { return true }
        let labels = parts[1].split(separator: ".")
        guard labels.count >= 3, let first = labels.first else { return false }
        return onSendingDomains.contains(local) && sendingSubdomains.contains(String(first))
    }

    static let marketingMarkers: [String] = [
        "view in browser", "view in your browser", "view this email in your browser", "view it in your browser",
        "view online", "view as a web page", "manage preferences", "manage your preferences", "email preferences",
        "update your preferences", "unsubscribe", "opt out of these emails",
    ]

    static func hasMarketingFooter(_ text: String) -> Bool {
        hasMarketingFooter(text, markers: marketingMarkers)
    }

    static func hasMarketingFooter(_ text: String, markers: [String]) -> Bool {
        let lower = replyPart(text).lowercased()
        return markers.contains { lower.contains($0.lowercased()) }
    }

    static let sellerPhrases: [String] = [
        "we help", "we've helped", "we have helped", "our platform", "our solution", "our agency", "our software",
        "our team helps", "we specialize", "we specialise", "i came across your", "came across your company",
        "i noticed your company", "i noticed that your", "partnership opportunity", "sponsorship opportunity",
        "explore a partnership", "partner with you", "i'm reaching out because", "i am reaching out because",
        "reaching out to see if",
    ]

    static let callToActionPhrases: [String] = [
        "quick call", "quick chat", "15 minutes", "15-minute", "15 min", "20 minutes", "30 minutes", "worth a chat",
        "open to a chat", "hop on a call", "jump on a call", "book a demo", "schedule a demo", "see a demo",
        "would love to connect", "i'd love to connect", "are you the right person", "who is the right person",
        "let me know if you're interested", "interested in learning more", "does next week work", "calendar link",
        "grab time", "find a time",
    ]

    static func isSellerLanguage(_ text: String) -> Bool {
        isSellerLanguage(text, sellerPhrases: sellerPhrases, callToActionPhrases: callToActionPhrases)
    }

    static func isSellerLanguage(_ text: String, sellerPhrases: [String], callToActionPhrases: [String]) -> Bool {
        let reply = " " + replyPart(text).lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") + " "
        return sellerPhrases.contains { reply.contains($0.lowercased()) }
            && callToActionPhrases.contains { reply.contains($0.lowercased()) }
    }

    static func isAcknowledgement(_ text: String) -> Bool {
        isAcknowledgement(text, maxWords: maximumAcknowledgementWords, phrases: acknowledgementPhrases,
                          actionWords: actionWords)
    }

    static func isAcknowledgement(_ text: String, maxWords: Int, phrases: [String], actionWords: Set<String>) -> Bool {
        let reply = replyPart(text)
        guard !reply.contains("?") else { return false }
        let words = reply.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= maxWords else { return false }
        guard !words.contains(where: actionWords.contains) else { return false }
        let joined = " " + words.joined(separator: " ") + " "
        return phrases.contains { joined.contains(" " + $0.lowercased() + " ") }
    }
}
