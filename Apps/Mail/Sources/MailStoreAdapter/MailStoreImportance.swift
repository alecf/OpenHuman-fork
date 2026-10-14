import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore

public final class MailStoreImportance: ImportanceRulesPort, Sendable {
    private let store: any ImportanceRulesStoring
    private let allowsChanges: Bool

    public init(store: any ImportanceRulesStoring, safeMode: SafeModeInfo) {
        self.store = store
        self.allowsChanges = safeMode != .readOnly
    }

    public func apply(_ change: ImportanceChange) async throws -> UndoToken {
        guard allowsChanges else { throw MailPortError.blockedBySafeMode }
        return try Self.token(Self.mapping { try store.addImportanceRule(Self.definition(change, store: store)) })
    }

    public func update(_ id: String, to change: ImportanceChange) async throws -> UndoToken {
        guard allowsChanges else { throw MailPortError.blockedBySafeMode }
        guard let raw = Int64(id) else { throw MailPortError.notFound("rule") }
        let ruleID = ImportanceRuleID(rawValue: raw)
        return try Self.token(Self.mapping {
            guard let current = try store.importanceRules(account: change.account).first(where: { $0.id == ruleID }) else {
                throw StoreError.notFound("importance rule")
            }
            var definition = try Self.definition(change, store: store)
            definition.accountID = current.definition.accountID
            return try store.updateImportanceRule(ruleID, to: definition)
        })
    }

    public func delete(_ ids: [String]) async throws -> UndoToken {
        guard allowsChanges else { throw MailPortError.blockedBySafeMode }
        let ruleIDs = ids.compactMap { Int64($0) }.map { ImportanceRuleID(rawValue: $0) }
        return try Self.token(Self.mapping { try store.deleteImportanceRules(ruleIDs) })
    }

    public func undo(_ token: UndoToken) async throws -> UndoToken? {
        guard allowsChanges else { throw MailPortError.blockedBySafeMode }
        let receipt: ImportanceRuleReceipt
        do { receipt = try JSONDecoder().decode(ImportanceRuleReceipt.self, from: token.payload) } catch {
            throw MailPortError.conflict("not an importance receipt")
        }
        guard let redo = try Self.mapping({ try store.undoImportanceRuleEdit(receipt) }) else { return nil }
        return try Self.token(redo)
    }

    public func explain(_ thread: ThreadKey) async throws -> ImportanceExplanation {
        let reason = try Self.mapping { try store.importanceReason(Self.ref(thread)) }
        return ImportanceExplanation(isImportant: reason.importance == .important,
                                     placement: reason.isInInbox ? reason.placementName : "Not in the inbox",
                                     reason: reason.reasonText, ruleID: reason.rule.map { String($0.id.rawValue) })
    }

    public func replyCounters(_ account: AccountID, since: Date) async throws -> [ContactReplyCounter] {
        guard let mailStore = store as? MailStore else { return [] }
        return try Self.mapping { try mailStore.sentReplies(account: account, since: since) }
            .map { ContactReplyCounter(email: $0.email, name: $0.name, repliedAt: $0.sentAt) }
    }

    public func rules(_ account: AccountID) -> AsyncThrowingStream<[ImportanceRuleInfo], Error> {
        MailStoreAdapter.map(store.observeImportanceRules(account: account).values()) { rules in
            rules.map { Self.info($0, account: account) }
        }
    }

    static func definition(_ change: ImportanceChange, store: any ImportanceRulesStoring) throws -> ImportanceRuleDefinition {
        let account = change.account
        switch change.kind {
        case .alwaysSender:
            return ImportanceRuleDefinition(accountID: account, kind: .sender, value: change.value, effect: .important)
        case .alwaysDomain:
            return ImportanceRuleDefinition(accountID: account, kind: .domain, value: change.value, effect: .important)
        case .neverSender:
            return ImportanceRuleDefinition(accountID: account, kind: .sender, value: change.value, effect: .neverImportant)
        case .neverDomain:
            return ImportanceRuleDefinition(accountID: account, kind: .domain, value: change.value, effect: .neverImportant)
        case .excludeFromSplit:
            return ImportanceRuleDefinition(accountID: account, kind: .sender, value: change.value, effect: .exemptFromSplit,
                                            splitID: change.split)
        case .notPitch:
            let reason = try change.thread.map { try store.importanceReason(Self.ref($0)) }
            return ImportanceRuleDefinition(accountID: account, kind: .sender, value: change.value, effect: .exemptFromSplit,
                                            splitID: reason?.placementSplitID ?? reason?.chipSplitIDs.first)
        case .alwaysThread, .neverThread:
            let id = change.value.isEmpty ? change.thread?.gmailThreadID.rawValue ?? "" : change.value
            return ImportanceRuleDefinition(accountID: account, kind: .matcher,
                                            value: ThreadImportanceMatcher.value(for: GmailThreadID(id)),
                                            effect: change.kind == .alwaysThread ? .important : .neverImportant)
        case .keyword, .label, .matcher:
            let kind: ImportanceMatchKind = switch change.kind {
            case .keyword: .keyword
            case .label: .label
            default: .matcher
            }
            let effect = storeEffect(change.effect)
            return ImportanceRuleDefinition(accountID: account, kind: kind, value: change.value, effect: effect,
                                            splitID: effect == .exemptFromSplit ? change.split : nil)
        }
    }

    static func storeEffect(_ effect: ImportanceRuleEffect) -> ImportanceEffect {
        switch effect {
        case .important: .important
        case .neverImportant: .neverImportant
        case .exemptFromSplit: .exemptFromSplit
        }
    }

    static func info(_ rule: ImportanceRule, account: AccountID) -> ImportanceRuleInfo {
        let d = rule.definition
        let thread = d.kind == .matcher ? ThreadImportanceMatcher.thread(inValue: d.value) : nil
        let match: ImportanceRuleMatch = switch d.kind {
        case .sender: .sender
        case .domain: .domain
        case .keyword: .keyword
        case .label: .label
        case .matcher: thread == nil ? .matcher : .thread
        }
        let effect: ImportanceRuleEffect = switch d.effect {
        case .important: .important
        case .neverImportant: .neverImportant
        case .exemptFromSplit: .exemptFromSplit
        }
        return ImportanceRuleInfo(id: String(rule.id.rawValue), kind: ImportanceRuleKind.kind(match: match, effect: effect),
                                  account: account, value: thread?.rawValue ?? d.value, split: d.splitID,
                                  createdAt: rule.createdAt,
                                  match: match, effect: effect, origin: d.source == .ai ? .ai : .user,
                                  appliesToEveryAccount: d.accountID == nil)
    }

    static func ref(_ key: ThreadKey) -> ThreadRef {
        ThreadRef(accountID: key.account, rowID: ThreadRowID(rawValue: key.rowID), gmailThreadID: key.gmailThreadID)
    }

    static func token(_ receipt: ImportanceRuleReceipt) throws -> UndoToken {
        UndoToken(payload: try JSONEncoder().encode(receipt))
    }

    static func mapping<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as StoreError {
            switch error {
            case .notFound: throw MailPortError.notFound("thread or rule")
            case .limitExceeded: throw MailPortError.limitExceeded("importance rules")
            default: throw MailPortError.conflict("importance rule")
            }
        }
    }
}
