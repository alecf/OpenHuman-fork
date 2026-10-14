import Foundation
import OpenHumanCore

public struct ImportanceRuleID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum ThreadImportance: String, Codable, Sendable, CaseIterable { case important, normal, suppressed }
public enum ImportanceMatchKind: String, Codable, Sendable, CaseIterable { case sender, domain, keyword, label, matcher }
public enum ImportanceEffect: String, Codable, Sendable, CaseIterable {
    case important, neverImportant = "never_important", exemptFromSplit = "exempt_from_split"
}
public enum ImportanceRuleSource: String, Codable, Sendable, CaseIterable { case user, ai }

public struct ImportanceRuleDefinition: Hashable, Codable, Sendable {
    public var accountID: AccountID?
    public var kind: ImportanceMatchKind
    public var value: String
    public var effect: ImportanceEffect
    public var splitID: SplitID? = nil
    public var source: ImportanceRuleSource = .user

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        accountID: AccountID? = nil,
        kind: ImportanceMatchKind,
        value: String,
        effect: ImportanceEffect,
        splitID: SplitID? = nil,
        source: ImportanceRuleSource = .user
    ) {
        self.accountID = accountID
        self.kind = kind
        self.value = value
        self.effect = effect
        self.splitID = splitID
        self.source = source
    }
    // end generated-init
}

public struct ImportanceRule: Identifiable, Hashable, Codable, Sendable {
    public var id: ImportanceRuleID; public var definition: ImportanceRuleDefinition
    public var createdAt: Date; public var updatedAt: Date

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: ImportanceRuleID,
        definition: ImportanceRuleDefinition,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.definition = definition
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    // end generated-init
}

public struct ImportanceRuleEdit: Hashable, Codable, Sendable {
    public var insert: [ImportanceRule]; public var delete: [ImportanceRule]

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        insert: [ImportanceRule],
        delete: [ImportanceRule]
    ) {
        self.insert = insert
        self.delete = delete
    }
    // end generated-init
}

public struct ImportanceRuleReceipt: Hashable, Codable, Sendable {
    public var ruleIDs: [ImportanceRuleID]
    public var undo: ImportanceRuleEdit?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        ruleIDs: [ImportanceRuleID],
        undo: ImportanceRuleEdit? = nil
    ) {
        self.ruleIDs = ruleIDs
        self.undo = undo
    }
    // end generated-init
}

public enum ImportanceBasis: String, Codable, Sendable { case rule, importanceSplit = "importance_split", none }

public struct ImportanceReason: Hashable, Sendable {
    public var thread: ThreadRef
    public var importance: ThreadImportance
    public var basis: ImportanceBasis
    public var rule: ImportanceRule?
    public var importanceSplitRuleText: String?
    public var isInInbox: Bool
    public var placementSplitID: SplitID?
    public var placementName: String
    public var chipSplitIDs: [SplitID]
    public var exemptions: [ImportanceRule]
    public var sender: String?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        thread: ThreadRef,
        importance: ThreadImportance,
        basis: ImportanceBasis,
        rule: ImportanceRule? = nil,
        importanceSplitRuleText: String? = nil,
        isInInbox: Bool,
        placementSplitID: SplitID? = nil,
        placementName: String,
        chipSplitIDs: [SplitID],
        exemptions: [ImportanceRule],
        sender: String? = nil
    ) {
        self.thread = thread
        self.importance = importance
        self.basis = basis
        self.rule = rule
        self.importanceSplitRuleText = importanceSplitRuleText
        self.isInInbox = isInInbox
        self.placementSplitID = placementSplitID
        self.placementName = placementName
        self.chipSplitIDs = chipSplitIDs
        self.exemptions = exemptions
        self.sender = sender
    }
    // end generated-init
}

public struct ImportanceCounts: Hashable, Sendable {
    public var accountID: AccountID
    public var important: Int; public var importantUnread: Int; public var normal: Int; public var suppressed: Int

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        accountID: AccountID,
        important: Int,
        importantUnread: Int,
        normal: Int,
        suppressed: Int
    ) {
        self.accountID = accountID
        self.important = important
        self.importantUnread = importantUnread
        self.normal = normal
        self.suppressed = suppressed
    }
    // end generated-init
}

public struct ImportanceRulesDocument: Hashable, Codable, Sendable {
    public var version: Int = 1
    public var rules: [ExportedImportanceRule]

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        version: Int = 1,
        rules: [ExportedImportanceRule]
    ) {
        self.version = version
        self.rules = rules
    }
    // end generated-init
}

public struct ExportedImportanceRule: Hashable, Codable, Sendable {
    public var account: String?
    public var kind: ImportanceMatchKind; public var value: String; public var effect: ImportanceEffect
    public var split: String? = nil
    public var source: ImportanceRuleSource = .user
    public var createdAt: Date

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        account: String? = nil,
        kind: ImportanceMatchKind,
        value: String,
        effect: ImportanceEffect,
        split: String? = nil,
        source: ImportanceRuleSource = .user,
        createdAt: Date
    ) {
        self.account = account
        self.kind = kind
        self.value = value
        self.effect = effect
        self.split = split
        self.source = source
        self.createdAt = createdAt
    }
    // end generated-init
}

public struct ImportanceImportSummary: Hashable, Sendable {
    public var added: Int; public var replaced: Int; public var unchanged: Int
    public var skipped: Int
    public var receipt: ImportanceRuleReceipt?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        added: Int,
        replaced: Int,
        unchanged: Int,
        skipped: Int,
        receipt: ImportanceRuleReceipt? = nil
    ) {
        self.added = added
        self.replaced = replaced
        self.unchanged = unchanged
        self.skipped = skipped
        self.receipt = receipt
    }
    // end generated-init
}

public protocol ImportanceMatcher: Sendable {
    var id: String { get }
    var readsText: Bool { get }
    func matches(_ facts: ImportanceFacts, argument: String) -> Bool
}

public struct ImportanceFacts: Hashable, Sendable {
    public var accountID: AccountID
    public var messages: [ImportanceMessageFacts]
    public var threadID: GmailThreadID? = nil

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        accountID: AccountID,
        messages: [ImportanceMessageFacts],
        threadID: GmailThreadID? = nil
    ) {
        self.accountID = accountID
        self.messages = messages
        self.threadID = threadID
    }
    // end generated-init
}

public struct ImportanceMessageFacts: Hashable, Sendable {
    public var from: EmailAddress?; public var to: [EmailAddress]; public var cc: [EmailAddress]
    public var date: Date; public var isFromMe: Bool; public var isUnread: Bool
    public var labelIDs: [GmailLabelID]
    public var subject: String
    public var text: String? = nil

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        from: EmailAddress? = nil,
        to: [EmailAddress],
        cc: [EmailAddress],
        date: Date,
        isFromMe: Bool,
        isUnread: Bool,
        labelIDs: [GmailLabelID],
        subject: String,
        text: String? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.isFromMe = isFromMe
        self.isUnread = isUnread
        self.labelIDs = labelIDs
        self.subject = subject
        self.text = text
    }
    // end generated-init
}

public protocol ImportanceRulesStoring: Sendable {
    func importanceRules(account: AccountID?) throws -> [ImportanceRule]
    func observeImportanceRules(account: AccountID?) -> StoreObservation<[ImportanceRule]>
    func addImportanceRule(_ definition: ImportanceRuleDefinition) throws -> ImportanceRuleReceipt
    func updateImportanceRule(_ id: ImportanceRuleID, to definition: ImportanceRuleDefinition) throws -> ImportanceRuleReceipt
    func deleteImportanceRules(_ ids: [ImportanceRuleID]) throws -> ImportanceRuleReceipt
    func undoImportanceRuleEdit(_ receipt: ImportanceRuleReceipt) throws -> ImportanceRuleReceipt?
    func setImportanceSplit(account: AccountID, _ id: SplitID?) throws
    func importanceReason(_ thread: ThreadRef) throws -> ImportanceReason
    func importanceCounts(account: AccountID) throws -> ImportanceCounts
    func observeImportanceCounts(account: AccountID) -> StoreObservation<ImportanceCounts>
    func exportImportanceRules(account: AccountID?) throws -> ImportanceRulesDocument
    func importImportanceRules(_ document: ImportanceRulesDocument, dryRun: Bool) throws -> ImportanceImportSummary
    func reevaluateImportance(account: AccountID?) throws
}
