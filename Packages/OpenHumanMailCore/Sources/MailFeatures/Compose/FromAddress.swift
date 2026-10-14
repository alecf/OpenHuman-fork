import Foundation
import MailModel
import OpenHumanCore

public struct FromIdentity: Identifiable, Hashable, Sendable {
    public let email: String
    public let name: String?
    public let isGmailDefault: Bool
    public let isPrimary: Bool
    public let signatureHTML: String?
    public let needsVerification: Bool

    public var id: String { email }

    public init(email: String, name: String? = nil, isGmailDefault: Bool = false, isPrimary: Bool = false,
                signatureHTML: String? = nil, needsVerification: Bool = false) {
        self.email = email.lowercased()
        self.name = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.isGmailDefault = isGmailDefault
        self.isPrimary = isPrimary
        self.signatureHTML = signatureHTML
        self.needsVerification = needsVerification
    }

    public var display: String {
        guard let name else { return email }
        return "\(name) <\(email)>"
    }

    public var address: EmailAddress { EmailAddress(name: name, email: email) }
}

public enum FromReason: Hashable, Sendable {
    case accountDefault
    case sentToAlias
    case lastUsedOnThread
    case rememberedForThread
    case chosen
    case draft

    public var text: String {
        switch self {
        case .accountDefault: String(localized: "Your default address")
        case .sentToAlias: String(localized: "The address this was sent to")
        case .lastUsedOnThread: String(localized: "Last used in this conversation")
        case .rememberedForThread: String(localized: "Your choice for this conversation")
        case .chosen: String(localized: "Chosen for this message")
        case .draft: String(localized: "Saved with the draft")
        }
    }
}

public enum ReplyFromPolicy: String, Codable, Sendable, CaseIterable, Hashable {
    case addressSentTo
    case accountDefault
    case lastUsedOnThread

    public var title: String {
        switch self {
        case .addressSentTo: String(localized: "Reply from the address it was sent to")
        case .accountDefault: String(localized: "Always use the default address")
        case .lastUsedOnThread: String(localized: "Use the address last used in the conversation")
        }
    }
}

public struct ThreadFromChoice: Codable, Hashable, Sendable {
    public var thread: String
    public var email: String

    public init(thread: String, email: String) {
        self.thread = thread
        self.email = email.lowercased()
    }
}

public enum ComposeSettings {
    public static func defaultFrom(_ account: AccountID) -> AppSettingKey<String?> {
        AppSettingKey(name: "compose.default_from", scope: .account(account), defaultValue: nil)
    }

    public static func replyFrom(_ account: AccountID) -> AppSettingKey<ReplyFromPolicy> {
        AppSettingKey(name: "compose.reply_from", scope: .account(account), defaultValue: .addressSentTo)
    }

    public static func threadFrom(_ account: AccountID) -> AppSettingKey<[ThreadFromChoice]> {
        AppSettingKey(name: "compose.from_by_thread", scope: .account(account), defaultValue: [])
    }

    public static let maxRememberedThreads = 500

    public static func remembering(_ choice: ThreadFromChoice, in list: [ThreadFromChoice]) -> [ThreadFromChoice] {
        var out = list.filter { $0.thread != choice.thread }
        out.append(choice)
        if out.count > maxRememberedThreads { out.removeFirst(out.count - maxRememberedThreads) }
        return out
    }
}

public enum FromResolver {
    public static func identities(of account: Account) -> [FromIdentity] {
        var out: [FromIdentity] = []
        var seen = Set<String>()
        let ordered = account.sendAs.filter(\.isDefault) + account.sendAs.filter { $0.isPrimary && !$0.isDefault }
            + account.sendAs.filter { !$0.isPrimary && !$0.isDefault }
        for identity in ordered where seen.insert(identity.email.lowercased()).inserted {
            out.append(FromIdentity(email: identity.email, name: identity.name ?? (identity.isPrimary ? account.displayName : nil),
                                    isGmailDefault: identity.isDefault, isPrimary: identity.isPrimary,
                                    signatureHTML: identity.signatureHTML, needsVerification: identity.needsVerification))
        }
        if seen.insert(account.email.lowercased()).inserted {
            out.insert(FromIdentity(email: account.email, name: account.displayName, isGmailDefault: out.isEmpty,
                                    isPrimary: true), at: 0)
        }
        return out
    }

    public static func defaultIdentity(_ identities: [FromIdentity], setting: String?) -> FromIdentity? {
        if let setting, let chosen = identities.first(where: { $0.email == setting.lowercased() && !$0.needsVerification }) {
            return chosen
        }
        return identities.first { $0.isGmailDefault && !$0.needsVerification }
            ?? identities.first { $0.isPrimary }
            ?? identities.first { !$0.needsVerification }
            ?? identities.first
    }

    public static func forNew(account: Account, defaultSetting: String?) -> (FromIdentity, FromReason) {
        let all = identities(of: account)
        return (defaultIdentity(all, setting: defaultSetting) ?? all[0], .accountDefault)
    }

    public static func forReply(account: Account, policy: ReplyFromPolicy, original: MessageSummary?,
                                thread: [MessageSummary], remembered: String?,
                                defaultSetting: String?) -> (FromIdentity, FromReason) {
        let all = identities(of: account)
        let usable = all.filter { !$0.needsVerification }
        func usableIdentity(_ address: String?) -> FromIdentity? {
            guard let address else { return nil }
            return usable.first { $0.email == address.lowercased() }
        }
        let fallback = (defaultIdentity(all, setting: defaultSetting) ?? all[0], FromReason.accountDefault)
        if let remembered, let chosen = all.first(where: { $0.email == remembered.lowercased() }) {
            return (chosen, .rememberedForThread)
        }
        switch policy {
        case .accountDefault:
            return fallback
        case .lastUsedOnThread:
            if let used = thread.reversed().compactMap({ $0.from?.email }).first(where: { account.isMe($0) }),
               let identity = usableIdentity(used) {
                return (identity, .lastUsedOnThread)
            }
            return sentTo(original, account: account, usable: usableIdentity) ?? fallback
        case .addressSentTo:
            return sentTo(original, account: account, usable: usableIdentity) ?? fallback
        }
    }

    static func sentTo(_ original: MessageSummary?, account: Account,
                       usable: (String?) -> FromIdentity?) -> (FromIdentity, FromReason)? {
        guard let original else { return nil }
        if let from = original.from?.email, account.isMe(from) {
            return usable(from).map { ($0, .sentToAlias) }
        }
        for address in original.to + original.cc + original.bcc where account.isMe(address.email) {
            if let identity = usable(address.email) { return (identity, .sentToAlias) }
        }
        return nil
    }
}
