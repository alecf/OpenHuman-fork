import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class VIPCenter {
    nonisolated public static let chipTitle = "VIP"

    public private(set) var revision = 0
    public private(set) var suggestEnabled = true

    public struct LastChange: Hashable, Sendable {
        public let title: String
        let token: UndoToken
    }

    public private(set) var lastChange: LastChange?

    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let importance: (any ImportanceRulesPort)?
    @ObservationIgnored private let settings: (any SettingsPort)?
    @ObservationIgnored private let undo: UndoCoordinator?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored let undoer: VIPUndoer?
    @ObservationIgnored private var marked: [AccountID: Set<String>] = [:]
    @ObservationIgnored private var declined: [AccountID: Set<String>] = [:]
    @ObservationIgnored private var rules: [AccountID: [ImportanceRuleInfo]] = [:]
    @ObservationIgnored private var accountTasks: [AccountID: [Task<Void, Never>]] = [:]
    @ObservationIgnored private var mainTasks: [Task<Void, Never>] = []

    public init(data: any MailDataSource, importance: (any ImportanceRulesPort)?, settings: (any SettingsPort)?,
                undo: UndoCoordinator?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.data = data
        self.importance = importance
        self.settings = settings
        self.undo = undo
        self.now = now
        undoer = importance.flatMap { importance in settings.map { VIPUndoer(importance: importance, settings: $0) } }
    }

    isolated deinit {
        for task in mainTasks { task.cancel() }
        for tasks in accountTasks.values { for task in tasks { task.cancel() } }
    }

    public func start() {
        guard mainTasks.isEmpty, importance != nil, let settings else { return }
        let data = self.data
        mainTasks.append(Task { [weak self] in
            do {
                for try await list in data.accounts() {
                    guard !Task.isCancelled else { return }
                    self?.follow(list.map(\.id))
                }
            } catch {}
        })
        mainTasks.append(Task { [weak self] in
            for await on in settings.observe(VIPSettings.suggest) {
                guard !Task.isCancelled else { return }
                self?.suggestEnabled = on
                self?.revision += 1
            }
        })
    }

    private func follow(_ ids: [AccountID]) {
        guard let importance, let settings else { return }
        for gone in accountTasks.keys where !ids.contains(gone) {
            accountTasks[gone]?.forEach { $0.cancel() }
            accountTasks[gone] = nil
            marked[gone] = nil
            declined[gone] = nil
            rules[gone] = nil
        }
        for id in ids where accountTasks[id] == nil {
            let rulesTask = Task { [weak self] in
                do {
                    for try await list in importance.rules(id) {
                        guard !Task.isCancelled else { return }
                        self?.rules[id] = list
                        self?.revision += 1
                    }
                } catch {}
            }
            let markedTask = Task { [weak self] in
                for await list in settings.observe(VIPSettings.marked(id)) {
                    guard !Task.isCancelled else { return }
                    self?.marked[id] = Set(list.map { $0.lowercased() })
                    self?.revision += 1
                }
            }
            let declinedTask = Task { [weak self] in
                for await list in settings.observe(VIPSettings.declined(id)) {
                    guard !Task.isCancelled else { return }
                    self?.declined[id] = Set(list.map { $0.lowercased() })
                    self?.revision += 1
                }
            }
            accountTasks[id] = [rulesTask, markedTask, declinedTask]
        }
    }

    private func alwaysSenders(_ account: AccountID) -> Set<String> {
        Set((rules[account] ?? []).filter { $0.kind == .alwaysSender }.map { $0.value.lowercased() })
    }

    public func isVIP(_ email: String, account: AccountID) -> Bool {
        _ = revision
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard marked[account]?.contains(address) == true else { return false }
        return alwaysSenders(account).contains(address)
    }

    func hasLoaded(_ account: AccountID) -> Bool {
        rules[account] != nil && marked[account] != nil && declined[account] != nil
    }

    public func vips(for account: AccountID) -> [String] {
        _ = revision
        return (marked[account] ?? []).intersection(alwaysSenders(account)).sorted()
    }

    public func hasVIPSender(_ row: ThreadRow) -> Bool {
        row.participants.contains { !$0.isMe && isVIP($0.email, account: row.id.account) }
    }

    public func suggestions(for account: AccountID) async -> [VIPSuggestion] {
        guard suggestEnabled, let importance, settings != nil else { return [] }
        let at = now()
        let counters = (try? await importance.replyCounters(account, since: at.addingTimeInterval(-VIPSuggestionPolicy.lookback)))
            ?? []
        let excluded = VIPSuggestionPolicy.exclusions(rules: rules[account] ?? [], marked: marked[account] ?? [],
                                                      declined: declined[account] ?? [])
        return VIPSuggestionPolicy.suggestions(counters, account: account, now: at, excludedSenders: excluded.senders,
                                               excludedDomains: excluded.domains)
    }

    public func suggestion(for email: String, account: AccountID) async -> VIPSuggestion? {
        let address = email.lowercased()
        return await suggestions(for: account).first { $0.email == address }
    }

    public func accept(_ suggestion: VIPSuggestion) async throws {
        guard let importance, let settings else { throw MailPortError.unsupported("VIPs") }
        let title = "Marked \(suggestion.displayName) as VIP"
        try await perform(title) {
            let rule = try await importance.apply(ImportanceChange(kind: .alwaysSender, account: suggestion.account,
                                                                   value: suggestion.email))
            do {
                try await VIPUndoer.update(settings, VIPSettings.marked(suggestion.account)) { $0.insert(suggestion.email) }
            } catch {
                _ = try? await importance.undo(rule)
                throw error
            }
            return VIPUndoer.token(.accept, account: suggestion.account, email: suggestion.email, rule: rule)
        }
        marked[suggestion.account, default: []].insert(suggestion.email)
        revision += 1
    }

    public func decline(_ suggestion: VIPSuggestion) async throws {
        guard let settings, undoer != nil else { throw MailPortError.unsupported("VIPs") }
        try await perform("Won't suggest \(suggestion.displayName) again") {
            try await VIPUndoer.update(settings, VIPSettings.declined(suggestion.account)) { $0.insert(suggestion.email) }
            return VIPUndoer.token(.decline, account: suggestion.account, email: suggestion.email, rule: nil)
        }
        declined[suggestion.account, default: []].insert(suggestion.email)
        revision += 1
    }

    public func setSuggestEnabled(_ on: Bool) async throws {
        guard let settings else { return }
        try await settings.set(VIPSettings.suggest, on)
        suggestEnabled = on
        revision += 1
    }

    public func resetSuggestions(accounts: [AccountID]) async throws {
        guard let settings else { return }
        for account in accounts {
            try await settings.set(VIPSettings.declined(account), [])
            declined[account] = []
        }
        revision += 1
    }

    public func undoLastChange() async throws {
        guard let change = lastChange, let undoer else { return }
        lastChange = nil
        _ = try await undoer.undo(change.token)
        revision += 1
    }

    private func perform(_ title: String, _ change: () async throws -> UndoToken) async throws {
        if let undo, let undoer {
            try await undo.perform("\(title)", via: undoer, change)
        } else {
            lastChange = LastChange(title: title, token: try await change())
        }
    }
}

public final class VIPUndoer: MailUndoing, Sendable {
    enum Operation: String, Codable { case accept, unaccept, decline, undecline }

    struct Receipt: Codable {
        var operation: Operation
        var account: Int64
        var email: String
        var rule: UndoToken?
    }

    private let importance: any ImportanceRulesPort
    private let settings: any SettingsPort

    init(importance: any ImportanceRulesPort, settings: any SettingsPort) {
        self.importance = importance
        self.settings = settings
    }

    static func token(_ operation: Operation, account: AccountID, email: String, rule: UndoToken?) -> UndoToken {
        let receipt = Receipt(operation: operation, account: account.rawValue, email: email, rule: rule)
        return UndoToken(payload: (try? JSONEncoder().encode(receipt)) ?? Data())
    }

    static func update(_ settings: any SettingsPort, _ key: AppSettingKey<[String]>,
                       _ change: @Sendable (inout Set<String>) -> Void) async throws {
        var set = Set(try await settings.get(key).map { $0.lowercased() })
        change(&set)
        try await settings.set(key, set.sorted())
    }

    public func undo(_ token: UndoToken) async throws -> UndoToken? {
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: token.payload) else {
            throw MailPortError.conflict("not a VIP receipt")
        }
        let account = AccountID(receipt.account)
        let email = receipt.email
        switch receipt.operation {
        case .accept:
            var redo: UndoToken?
            if let rule = receipt.rule { redo = try await importance.undo(rule) }
            try await Self.update(settings, VIPSettings.marked(account)) { $0.remove(email) }
            return Self.token(.unaccept, account: account, email: email, rule: redo)
        case .unaccept:
            var again: UndoToken?
            if let rule = receipt.rule { again = try await importance.undo(rule) }
            try await Self.update(settings, VIPSettings.marked(account)) { $0.insert(email) }
            return Self.token(.accept, account: account, email: email, rule: again)
        case .decline:
            try await Self.update(settings, VIPSettings.declined(account)) { $0.remove(email) }
            return Self.token(.undecline, account: account, email: email, rule: nil)
        case .undecline:
            try await Self.update(settings, VIPSettings.declined(account)) { $0.insert(email) }
            return Self.token(.decline, account: account, email: email, rule: nil)
        }
    }
}
