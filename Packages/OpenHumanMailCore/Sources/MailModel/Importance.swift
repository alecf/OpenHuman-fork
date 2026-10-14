import Foundation
import OpenHumanCore

public enum ImportanceRuleKind: String, Sendable, Hashable, Codable, CaseIterable {
    case alwaysSender
    case alwaysDomain
    case neverSender
    case excludeFromSplit
    case notPitch
    case neverDomain
    case keyword
    case label
    case matcher
    case alwaysThread
    case neverThread

    public var match: ImportanceRuleMatch {
        switch self {
        case .alwaysSender, .neverSender, .excludeFromSplit, .notPitch: .sender
        case .alwaysDomain, .neverDomain: .domain
        case .keyword: .keyword
        case .label: .label
        case .matcher: .matcher
        case .alwaysThread, .neverThread: .thread
        }
    }

    public var impliedEffect: ImportanceRuleEffect? {
        switch self {
        case .alwaysSender, .alwaysDomain, .alwaysThread: .important
        case .neverSender, .neverDomain, .neverThread: .neverImportant
        case .excludeFromSplit, .notPitch: .exemptFromSplit
        case .keyword, .label, .matcher: nil
        }
    }

    public static func kind(match: ImportanceRuleMatch, effect: ImportanceRuleEffect) -> ImportanceRuleKind {
        switch (match, effect) {
        case (.sender, .important): .alwaysSender
        case (.sender, .neverImportant): .neverSender
        case (.domain, .important): .alwaysDomain
        case (.domain, .neverImportant): .neverDomain
        case (.thread, .important): .alwaysThread
        case (.thread, .neverImportant): .neverThread
        case (_, .exemptFromSplit): .excludeFromSplit
        case (.keyword, _): .keyword
        case (.label, _): .label
        case (.matcher, _): .matcher
        }
    }
}

public enum ImportanceRuleMatch: String, Sendable, Hashable, Codable, CaseIterable {
    case sender, thread, domain, label, keyword, matcher
}

public enum ImportanceRuleEffect: String, Sendable, Hashable, Codable, CaseIterable {
    case important
    case neverImportant
    case exemptFromSplit
}

public enum ImportanceRuleOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    case user, ai
}

public struct ImportanceChange: Sendable, Hashable, Codable {
    public let kind: ImportanceRuleKind
    public let account: AccountID
    public let value: String
    public let split: SplitKey?
    public let thread: ThreadKey?
    public let effect: ImportanceRuleEffect

    public init(kind: ImportanceRuleKind, account: AccountID, value: String, split: SplitKey? = nil,
                thread: ThreadKey? = nil, effect: ImportanceRuleEffect? = nil) {
        self.kind = kind
        self.account = account
        switch kind {
        case .label, .matcher, .alwaysThread, .neverThread: self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        default: self.value = value.lowercased()
        }
        self.split = split
        self.thread = thread
        self.effect = kind.impliedEffect ?? effect ?? .important
    }
}

public struct ImportanceRuleInfo: Identifiable, Sendable, Hashable {
    public let id: String
    public let kind: ImportanceRuleKind
    public let account: AccountID
    public let value: String
    public let split: SplitKey?
    public let createdAt: Date
    public let match: ImportanceRuleMatch
    public let effect: ImportanceRuleEffect
    public let origin: ImportanceRuleOrigin
    public let appliesToEveryAccount: Bool

    public init(id: String, kind: ImportanceRuleKind, account: AccountID, value: String, split: SplitKey?,
                createdAt: Date, match: ImportanceRuleMatch? = nil, effect: ImportanceRuleEffect? = nil,
                origin: ImportanceRuleOrigin = .user, appliesToEveryAccount: Bool = false) {
        self.id = id
        self.kind = kind
        self.account = account
        self.value = value
        self.split = split
        self.createdAt = createdAt
        self.match = match ?? kind.match
        self.effect = effect ?? kind.impliedEffect ?? .important
        self.origin = origin
        self.appliesToEveryAccount = appliesToEveryAccount
    }
}

public struct ImportanceExplanation: Sendable, Hashable {
    public let isImportant: Bool
    public let placement: String
    public let reason: String
    public let ruleID: String?

    public init(isImportant: Bool, placement: String, reason: String, ruleID: String? = nil) {
        self.isImportant = isImportant
        self.placement = placement
        self.reason = reason
        self.ruleID = ruleID
    }

    public var line: String { "In \(placement): \(reason)" }
}

public protocol ImportanceRulesPort: MailUndoing {
    func apply(_ change: ImportanceChange) async throws -> UndoToken
    func explain(_ thread: ThreadKey) async throws -> ImportanceExplanation
    func rules(_ account: AccountID) -> AsyncThrowingStream<[ImportanceRuleInfo], Error>
    func update(_ id: String, to change: ImportanceChange) async throws -> UndoToken
    func delete(_ ids: [String]) async throws -> UndoToken
    func replyCounters(_ account: AccountID, since: Date) async throws -> [ContactReplyCounter]
}

extension ImportanceRulesPort {
    public func replyCounters(_ account: AccountID, since: Date) async throws -> [ContactReplyCounter] { [] }
}

extension ImportanceRulesPort {
    public func update(_ id: String, to change: ImportanceChange) async throws -> UndoToken {
        throw MailPortError.unsupported("editing importance rules")
    }

    public func delete(_ ids: [String]) async throws -> UndoToken {
        throw MailPortError.unsupported("deleting importance rules")
    }
}
