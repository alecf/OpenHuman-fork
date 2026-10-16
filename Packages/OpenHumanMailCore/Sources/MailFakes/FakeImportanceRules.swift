import Foundation
import MailModel
import OpenHumanCore
import Synchronization

public final class FakeImportanceRules: ImportanceRulesPort, Sendable {
    public struct ThreadFacts: Sendable, Hashable {
        public var sender: String?
        public var gmailImportant: Bool
        public var subject: String?
        public var labels: [String]

        public init(sender: String?, gmailImportant: Bool, subject: String? = nil, labels: [String] = []) {
            self.sender = sender?.lowercased()
            self.gmailImportant = gmailImportant
            self.subject = subject
            self.labels = labels
        }
    }

    struct Rule: Codable, Hashable, Sendable {
        var seq: Int
        var id: String
        var kind: ImportanceRuleKind
        var account: AccountID
        var value: String
        var split: SplitKey?
        var createdAt: Date
        var effect: ImportanceRuleEffect
    }

    struct Edit: Codable {
        var add: [Rule]
        var remove: [Rule]
        var inverse: Edit { Edit(add: remove, remove: add) }
    }

    struct State {
        var rules: [Rule] = []
        var facts: [ThreadKey: ThreadFacts] = [:]
        var nextID = 1
        var failNext: MailPortError?
        var autoLabel: (@Sendable (ThreadKey) -> String?)?
        var gmailImportant: (@Sendable (ThreadKey) -> Bool?)?
        var observers: [UUID: (AccountID, AsyncThrowingStream<[ImportanceRuleInfo], Error>.Continuation)] = [:]
    }

    private let state: Mutex<State>
    private let now: @Sendable () -> Date

    public init(corpus: FakeCorpus? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        var facts: [ThreadKey: ThreadFacts] = [:]
        for thread in corpus?.mailboxes.flatMap(\.threads) ?? [] {
            let sender = thread.row.participants.first { !$0.isMe }?.email
            facts[thread.row.id] = ThreadFacts(sender: sender, gmailImportant: thread.row.isImportant,
                                               subject: thread.row.subject)
        }
        state = Mutex(State(facts: facts))
        self.now = now
    }

    public func apply(_ change: ImportanceChange) async throws -> UndoToken {
        let (token, notify) = try state.withLock { s -> (UndoToken, [Notify]) in
            try Self.checkWritable(&s)
            let removed = s.rules.filter { Self.isReplaced($0, by: change) }
            let rule = Rule(seq: s.nextID, id: "rule-\(s.nextID)", kind: change.kind, account: change.account, value: change.value,
                            split: change.split, createdAt: now(), effect: change.effect)
            s.nextID += 1
            if let thread = change.thread, s.facts[thread]?.sender == nil, change.kind.match == .sender {
                s.facts[thread, default: ThreadFacts(sender: nil, gmailImportant: false)].sender = change.value
            }
            let edit = Edit(add: [rule], remove: removed)
            Self.perform(edit, in: &s)
            return (try Self.token(edit), Self.notifications(s, account: change.account))
        }
        notify.forEach { $0() }
        return token
    }

    public func update(_ id: String, to change: ImportanceChange) async throws -> UndoToken {
        let (token, notify) = try state.withLock { s -> (UndoToken, [Notify]) in
            try Self.checkWritable(&s)
            guard let old = s.rules.first(where: { $0.id == id && $0.account == change.account }) else {
                throw MailPortError.notFound("rule")
            }
            let removed = s.rules.filter { $0.id != id && Self.isReplaced($0, by: change) }
            let new = Rule(seq: old.seq, id: old.id, kind: change.kind, account: old.account, value: change.value,
                           split: change.split, createdAt: old.createdAt, effect: change.effect)
            let edit = Edit(add: [new], remove: [old] + removed)
            Self.perform(edit, in: &s)
            return (try Self.token(edit), Self.notifications(s, account: old.account))
        }
        notify.forEach { $0() }
        return token
    }

    public func delete(_ ids: [String]) async throws -> UndoToken {
        let (token, notify) = try state.withLock { s -> (UndoToken, [Notify]) in
            try Self.checkWritable(&s)
            let wanted = Set(ids)
            let removed = s.rules.filter { wanted.contains($0.id) }
            let edit = Edit(add: [], remove: removed)
            Self.perform(edit, in: &s)
            let accounts = Set(removed.map(\.account))
            return (try Self.token(edit), accounts.flatMap { Self.notifications(s, account: $0) })
        }
        notify.forEach { $0() }
        return token
    }

    public func undo(_ token: UndoToken) async throws -> UndoToken? {
        let edit = try JSONDecoder().decode(Edit.self, from: token.payload)
        let (redo, notify) = try state.withLock { s -> (UndoToken?, [Notify]) in
            try Self.checkWritable(&s)
            guard Self.canUndo(edit, in: s) else { return (nil, []) }
            Self.perform(edit.inverse, in: &s)
            let accounts = Set((edit.add + edit.remove).map(\.account))
            return (try Self.token(edit.inverse), accounts.flatMap { Self.notifications(s, account: $0) })
        }
        notify.forEach { $0() }
        return redo
    }

    public func explain(_ thread: ThreadKey) async throws -> ImportanceExplanation {
        state.withLock { s in
            var facts = s.facts[thread] ?? ThreadFacts(sender: nil, gmailImportant: false)
            if let marked = s.gmailImportant?(thread) { facts.gmailImportant = marked }
            let gmail = facts.gmailImportant
            let rules = Array(s.rules.filter { $0.account == thread.account }.reversed())
            let category = s.autoLabel?(thread) ?? Self.labelCategory(facts.labels)
            if let rule = Self.decidingRule(rules, facts, thread: thread, category: category) {
                let important = rule.effect == .important
                return ImportanceExplanation(isImportant: important, placement: important ? "Important" : "Other",
                                             reason: Self.reason(rule), ruleID: rule.id, gmailImportant: gmail)
            }
            if let sender = facts.sender {
                if let rule = rules.first(where: { $0.value == sender && $0.kind == .notPitch }) {
                    return ImportanceExplanation(isImportant: gmail, placement: gmail ? "Important" : "Other",
                                                 reason: "Not a pitch (\(sender))", ruleID: rule.id, gmailImportant: gmail)
                }
                if let rule = rules.first(where: { $0.value == sender && $0.kind == .excludeFromSplit }) {
                    return ImportanceExplanation(isImportant: gmail, placement: "Other",
                                                 reason: "Removed from a split for \(sender)", ruleID: rule.id,
                                                 gmailImportant: gmail)
                }
            }
            return gmail
                ? ImportanceExplanation(isImportant: true, placement: "Important", reason: "Gmail marked it important",
                                        gmailImportant: true)
                : ImportanceExplanation(isImportant: false, placement: "Other", reason: "No rule matched")
        }
    }

    public func rules(_ account: AccountID) -> AsyncThrowingStream<[ImportanceRuleInfo], Error> {
        let (stream, continuation) = AsyncThrowingStream<[ImportanceRuleInfo], Error>.makeStream()
        let id = UUID()
        let current = state.withLock { s in
            s.observers[id] = (account, continuation)
            return Self.infos(s, account: account)
        }
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.observers.removeValue(forKey: id) } }
        return stream
    }

    public var allRules: [ImportanceRuleInfo] { state.withLock { s in s.rules.map(Self.info) } }

    public func failNext(_ error: MailPortError) { state.withLock { $0.failNext = error } }

    public func setAutoLabelLookup(_ lookup: (@Sendable (ThreadKey) -> String?)?) {
        state.withLock { $0.autoLabel = lookup }
    }

    public func setGmailImportantLookup(_ lookup: (@Sendable (ThreadKey) -> Bool?)?) {
        state.withLock { $0.gmailImportant = lookup }
    }

    public func learn(_ thread: ThreadKey, _ facts: ThreadFacts) { state.withLock { $0.facts[thread] = facts } }

    private typealias Notify = @Sendable () -> Void

    private static func checkWritable(_ s: inout State) throws {
        if let failure = s.failNext {
            s.failNext = nil
            throw failure
        }
    }

    private static func replacedKinds(_ kind: ImportanceRuleKind) -> Set<ImportanceRuleKind> {
        switch kind {
        case .alwaysSender, .neverSender: [.alwaysSender, .neverSender]
        case .alwaysDomain, .neverDomain: [.alwaysDomain, .neverDomain]
        case .excludeFromSplit: [.excludeFromSplit]
        case .notPitch: [.notPitch]
        case .keyword: [.keyword]
        case .label: [.label]
        case .matcher: [.matcher]
        case .alwaysThread, .neverThread: [.alwaysThread, .neverThread]
        }
    }

    private static func isReplaced(_ rule: Rule, by change: ImportanceChange) -> Bool {
        rule.account == change.account && rule.value == change.value && replacedKinds(change.kind).contains(rule.kind)
            && (change.kind != .excludeFromSplit || rule.split == change.split)
    }

    private static func canUndo(_ edit: Edit, in s: State) -> Bool {
        guard edit.add.allSatisfy({ s.rules.contains($0) }) else { return false }
        let freed = Set(edit.add.map(\.id))
        return edit.remove.allSatisfy { rule in freed.contains(rule.id) || !s.rules.contains { $0.id == rule.id } }
    }

    private static func decidingRule(_ rules: [Rule], _ facts: ThreadFacts, thread: ThreadKey,
                                     category: String? = nil) -> Rule? {
        for level in ImportanceRuleMatch.allCases {
            let matching = rules.filter {
                $0.effect != .exemptFromSplit && $0.kind.match == level
                    && Self.matches($0, facts, thread: thread, category: category)
            }
            if let never = matching.first(where: { $0.effect == .neverImportant }) { return never }
            if let always = matching.first { return always }
        }
        return nil
    }

    private static func labelCategory(_ names: [String]) -> String? {
        let found = names.compactMap { OHGmailLabels.autoLabelCategory(inLabelName: $0) }
        return OHGmailLabels.autoLabelCategories.first { found.contains($0) }
    }

    private static func matches(_ rule: Rule, _ facts: ThreadFacts, thread: ThreadKey, category: String? = nil) -> Bool {
        switch rule.kind.match {
        case .sender:
            return facts.sender == rule.value
        case .thread:
            return thread.gmailThreadID.rawValue == rule.value
        case .domain:
            guard let sender = facts.sender, let at = sender.lastIndex(of: "@") else { return false }
            let host = String(sender[sender.index(after: at)...])
            return host == rule.value || host.hasSuffix("." + rule.value)
        case .keyword:
            return facts.subject?.lowercased().contains(rule.value) ?? false
        case .label:
            return facts.labels.contains { $0.caseInsensitiveCompare(rule.value) == .orderedSame }
        case .matcher:
            guard let wanted = AutoLabelRule.category(inValue: rule.value), let category else { return false }
            return wanted == category
        }
    }

    private static func reason(_ rule: Rule) -> String {
        let verb = rule.effect == .important ? "Always important" : "Never important"
        switch rule.kind.match {
        case .sender, .domain: return "\(verb) from \(rule.value)"
        case .keyword: return "\(verb) when it mentions \u{201C}\(rule.value)\u{201D}"
        case .label: return "\(verb) with the label \(rule.value)"
        case .matcher:
            if let category = AutoLabelRule.category(inValue: rule.value) {
                return rule.effect == .important ? "Auto label \(category) is important" : "Auto label \(category) goes to Other"
            }
            return "\(verb) by the \(rule.value) rule"
        case .thread:
            return rule.effect == .important ? "Moved to Important (this conversation only)"
                : "Moved to Other (this conversation only)"
        }
    }

    private static func perform(_ edit: Edit, in s: inout State) {
        let removing = Set(edit.remove.map(\.id))
        s.rules.removeAll { removing.contains($0.id) }
        s.rules.append(contentsOf: edit.add)
        s.rules.sort { $0.seq < $1.seq }
    }

    private static func token(_ edit: Edit) throws -> UndoToken {
        UndoToken(payload: try JSONEncoder().encode(edit))
    }

    private static func info(_ rule: Rule) -> ImportanceRuleInfo {
        ImportanceRuleInfo(id: rule.id, kind: rule.kind, account: rule.account, value: rule.value, split: rule.split,
                           createdAt: rule.createdAt, match: rule.kind.match, effect: rule.effect)
    }

    private static func infos(_ s: State, account: AccountID) -> [ImportanceRuleInfo] {
        s.rules.filter { $0.account == account }.reversed().map(info)
    }

    private static func notifications(_ s: State, account: AccountID) -> [Notify] {
        let infos = infos(s, account: account)
        return s.observers.values.filter { $0.0 == account }.map { observer in
            let continuation = observer.1
            return { continuation.yield(infos) }
        }
    }
}
