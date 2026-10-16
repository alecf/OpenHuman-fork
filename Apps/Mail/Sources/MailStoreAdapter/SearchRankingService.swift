import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore
import Synchronization

public protocol SearchRankingSource: Sendable {
    func ranking(for text: String, hybrid: Bool) -> any SearchRanking
    func changes() -> AsyncStream<Void>
}

final class SearchRankingService: SearchRankingPort, SearchRankingSource {
    typealias Resolve = @Sendable (AccountID, GmailThreadID) -> ThreadRowID?

    static let settingsKey = "dev.openhuman.mail.search.ranking.v1"
    static let forgetBelow = 0.05
    static let maximumRemembered = 2_000

    enum Persistence: Sendable {
        case memory
        case defaults(suite: String?)

        func load() -> SearchRankingSettings {
            guard case .defaults(let suite) = self else { return .defaults }
            let defaults = suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
            guard let data = defaults.data(forKey: SearchRankingService.settingsKey),
                  let settings = try? JSONDecoder().decode(SearchRankingSettings.self, from: data) else { return .defaults }
            return settings
        }

        func save(_ settings: SearchRankingSettings) {
            guard case .defaults(let suite) = self, let data = try? JSONEncoder().encode(settings) else { return }
            (suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard).set(data, forKey: SearchRankingService.settingsKey)
        }
    }

    struct Key: Hashable, Sendable {
        let account: AccountID
        let thread: GmailThreadID
    }

    private struct State {
        var settings: SearchRankingSettings
        var override: SearchSortOverride?
        var opens: [Key: SearchClickHistory]
        var rows: [Key: ThreadRowID] = [:]
        var resolvedStored = false
        var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private let state: Mutex<State>
    private let persistence: Persistence
    private let learning: any SearchLearningStoring
    private let resolve: Resolve
    private let now: @Sendable () -> Date

    init(persistence: Persistence, learning: any SearchLearningStoring, resolve: @escaping Resolve,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.persistence = persistence
        self.learning = learning
        self.resolve = resolve
        self.now = now
        var opens: [Key: SearchClickHistory] = [:]
        for entry in learning.initialEntries { opens[Key(account: entry.account, thread: entry.thread)] = entry.history }
        state = Mutex(State(settings: persistence.load(), opens: opens))
    }

    func settings() -> SearchRankingSettings { state.withLock { $0.settings } }

    func save(_ settings: SearchRankingSettings) {
        let changed = state.withLock { s in
            guard s.settings != settings else { return false }
            s.settings = settings
            return true
        }
        guard changed else { return }
        persistence.save(settings)
        notify()
    }

    func sortOverride() -> SearchSortOverride? { state.withLock { $0.override } }

    func setSortOverride(_ override: SearchSortOverride?) {
        let changed = state.withLock { s in
            guard s.override != override else { return false }
            s.override = override
            return true
        }
        if changed { notify() }
    }

    func recordOpen(_ thread: ThreadKey) async {
        let key = Key(account: thread.account, thread: thread.gmailThreadID)
        let at = now()
        let (entry, forgotten) = state.withLock { s -> (SearchLearningEntry, [Key]) in
            let halfLife = (s.settings.weights ?? .balanced).clickHalfLifeDays
            let history = (s.opens[key] ?? SearchClickHistory(score: 0, at: at)).adding(at: at, halfLifeDays: halfLife)
            s.opens[key] = history
            s.rows[key] = ThreadRowID(rawValue: thread.rowID)
            let forgotten = Self.prune(&s, now: at, halfLifeDays: halfLife, keeping: key)
            return (SearchLearningEntry(account: key.account, thread: key.thread, history: history), forgotten)
        }
        await learning.put(entry)
        if !forgotten.isEmpty { await learning.remove(forgotten.map { ($0.account, $0.thread) }) }
    }

    func rememberedConversations() async -> Int { state.withLock { $0.opens.count } }

    func resetLearning() async {
        state.withLock { s in
            s.opens = [:]
            s.rows = [:]
        }
        await learning.removeAll()
    }

    func ranking(for text: String, hybrid: Bool) -> any SearchRanking {
        let (settings, override) = state.withLock { ($0.settings, $0.override) }
        let sort = override.flatMap { $0.query == text ? $0.sort : nil } ?? settings.sort
        if sort == .recent { return NewestFirstSearchRanking() }
        guard let weights = settings.weights else { return hybrid ? HybridRRFRanking() : BM25RecencyRanking() }
        return BlendedSearchRanking(weights: Self.storeWeights(weights), clicks: clicks())
    }

    func clicks() -> [ThreadRowID: SearchClickHistory] {
        let pending = state.withLock { s in s.resolvedStored ? [] : s.opens.keys.filter { s.rows[$0] == nil } }
        var found: [Key: ThreadRowID] = [:]
        for key in pending {
            if let row = resolve(key.account, key.thread) { found[key] = row }
        }
        return state.withLock { s in
            for (key, row) in found { s.rows[key] = row }
            s.resolvedStored = true
            var out: [ThreadRowID: SearchClickHistory] = [:]
            for (key, history) in s.opens {
                if let row = s.rows[key] { out[row] = history }
            }
            return out
        }
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            self.state.withLock { $0.listeners[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.listeners.removeValue(forKey: id) }
            }
        }
    }

    var listenerCount: Int { state.withLock { $0.listeners.count } }

    private func notify() {
        let listeners = state.withLock { Array($0.listeners.values) }
        for listener in listeners { listener.yield() }
    }

    private static func prune(_ s: inout State, now: Date, halfLifeDays: Double, keeping: Key) -> [Key] {
        var forgotten = s.opens.filter { $0.key != keeping && $0.value.decayed(at: now, halfLifeDays: halfLifeDays) < forgetBelow }
            .map(\.key)
        let excess = s.opens.count - forgotten.count - maximumRemembered
        if excess > 0 {
            let gone = Set(forgotten)
            let weakest = s.opens.filter { $0.key != keeping && !gone.contains($0.key) }
                .sorted { ($0.value.decayed(at: now, halfLifeDays: halfLifeDays), $0.key.thread.rawValue)
                    < ($1.value.decayed(at: now, halfLifeDays: halfLifeDays), $1.key.thread.rawValue) }
                .prefix(excess).map(\.key)
            forgotten += weakest
        }
        for key in forgotten {
            s.opens[key] = nil
            s.rows[key] = nil
        }
        return forgotten
    }

    static func storeWeights(_ w: SearchRankingWeights) -> BlendedSearchRanking.Weights {
        BlendedSearchRanking.Weights(fields: w.fields, text: w.text, meaning: w.meaning, recency: w.recency, clicks: w.clicks,
                                     contacts: w.contacts, halfLifeDays: w.halfLifeDays,
                                     clickHalfLifeDays: w.clickHalfLifeDays)
    }

    static func explanation(_ breakdown: SearchScoreBreakdown) -> SearchScoreExplanation {
        SearchScoreExplanation(match: breakdown.match?.label, wordsTogether: breakdown.wordsTogether,
                               parts: breakdown.parts.map { .init(label: $0.signal.label, value: $0.value, weight: $0.weight) })
    }

    static func ordering(_ ordering: SearchOrdering) -> SearchResultsOrdering {
        switch ordering {
        case .date: .date
        case .relevance: .relevance
        }
    }
}
