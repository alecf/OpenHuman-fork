import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class SpotlightIndexer {
    public static let maxThreadsPerAccount = 500
    public static let defaultBatchSize = 50
    public static func ledgerKey(_ account: AccountID) -> String { "spotlight.indexedIDs.\(account.rawValue)" }

    public private(set) var indexedCount = 0
    public private(set) var isPaused = false
    public private(set) var lastFailed = false
    public private(set) var includesSubjects = false

    @ObservationIgnored public var batchSize = SpotlightIndexer.defaultBatchSize
    @ObservationIgnored public var debounce: Duration = .seconds(2)
    @ObservationIgnored public var pauseInterval: Duration = .seconds(5)

    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let settings: (any SettingsPort)?
    @ObservationIgnored private let index: any SpotlightIndexing
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var accountTasks: [AccountID: [Task<Void, Never>]] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var latest: [AccountID: [ThreadRow]] = [:]
    @ObservationIgnored private var names: [AccountID: [Int64: String]] = [:]
    @ObservationIgnored private var sent: [AccountID: [String: Int]] = [:]
    @ObservationIgnored private var dirty: [AccountID] = []
    @ObservationIgnored private var operations: [Operation] = []
    @ObservationIgnored private var backfillBusy = false
    @ObservationIgnored private var started = false

    private enum Operation {
        case upsert(AccountID, [SpotlightItem])
        case delete(AccountID, [String])
        case deleteDomain(AccountID)
    }

    public init(data: any MailDataSource, settings: (any SettingsPort)?, index: any SpotlightIndexing, defaults: UserDefaults) {
        self.data = data
        self.settings = settings
        self.index = index
        self.defaults = defaults
    }

    isolated deinit {
        for task in tasks { task.cancel() }
        for list in accountTasks.values { for task in list { task.cancel() } }
        worker?.cancel()
    }

    public func start() {
        guard !started else { return }
        started = true
        let data = self.data
        tasks.append(Task { [weak self] in
            do {
                for try await accounts in data.accounts() {
                    guard let self else { return }
                    self.follow(accounts.map(\.id))
                }
            } catch {}
        })
        tasks.append(Task { [weak self] in
            for await progress in data.syncProgress() {
                guard let self else { return }
                self.setBackfillBusy(!progress.isEmpty)
            }
        })
        if let settings {
            tasks.append(Task { [weak self] in
                for await value in settings.observe(AppSettings.spotlightIndexSubjects) {
                    guard let self else { return }
                    self.setIncludesSubjects(value)
                }
            })
        }
    }

    public func stop() {
        started = false
        for task in tasks { task.cancel() }
        tasks = []
        for list in accountTasks.values { for task in list { task.cancel() } }
        accountTasks = [:]
        worker?.cancel()
        worker = nil
        operations = []
        dirty = []
    }

    private func follow(_ accounts: [AccountID]) {
        let wanted = Set(accounts)
        for id in Array(accountTasks.keys) where !wanted.contains(id) { forget(id) }
        for id in accounts where accountTasks[id] == nil {
            let data = self.data
            let window = Task { [weak self] in
                do {
                    for try await window in data.threadWindow(.system(.inbox), account: id, limit: Self.maxThreadsPerAccount) {
                        guard let self else { return }
                        self.latest[id] = window.rows
                        self.markDirty(id)
                    }
                } catch {}
            }
            let labels = Task { [weak self] in
                do {
                    for try await list in data.labels(id) {
                        guard let self else { return }
                        self.names[id] = Dictionary(list.filter { $0.kind == .user || $0.kind == .category }.map { ($0.id, $0.displayName) },
                                                    uniquingKeysWith: { first, _ in first })
                        self.markDirty(id)
                    }
                } catch {}
            }
            accountTasks[id] = [window, labels]
        }
    }

    private func forget(_ account: AccountID) {
        drop(account)
        operations.append(.deleteDomain(account))
        kick()
    }

    public func removeAccount(_ account: AccountID) async {
        drop(account)
        do {
            try await index.delete(domains: [SpotlightIdentifier.domain(account)])
            lastFailed = false
        } catch {
            lastFailed = true
            operations.append(.deleteDomain(account))
        }
    }

    private func drop(_ account: AccountID) {
        for task in accountTasks[account] ?? [] { task.cancel() }
        accountTasks[account] = nil
        latest[account] = nil
        names[account] = nil
        sent[account] = nil
        dirty.removeAll { $0 == account }
        operations.removeAll { operation in
            switch operation {
            case .upsert(let a, _), .delete(let a, _), .deleteDomain(let a): a == account
            }
        }
        defaults.removeObject(forKey: Self.ledgerKey(account))
        updateCount()
    }

    func setBackfillBusy(_ busy: Bool) {
        backfillBusy = busy
        if !busy, worker == nil, !operations.isEmpty || !dirty.isEmpty { kick() }
    }

    func setIncludesSubjects(_ value: Bool) {
        guard value != includesSubjects else { return }
        includesSubjects = value
        sent = sent.mapValues { _ in [:] }
        for account in latest.keys { markDirty(account) }
    }

    private func markDirty(_ account: AccountID) {
        if !dirty.contains(account) { dirty.append(account) }
        kick()
    }

    public func rebuild() async {
        worker?.cancel()
        worker = nil
        operations = []
        dirty = []
        sent = [:]
        for account in latest.keys { defaults.removeObject(forKey: Self.ledgerKey(account)) }
        do {
            try await index.deleteAll()
            lastFailed = false
        } catch { lastFailed = true }
        updateCount()
        for account in latest.keys { markDirty(account) }
    }

    public func removeAll() async {
        stop()
        for account in Array(sent.keys) { defaults.removeObject(forKey: Self.ledgerKey(account)) }
        for account in latest.keys { defaults.removeObject(forKey: Self.ledgerKey(account)) }
        sent = [:]
        latest = [:]
        do {
            try await index.deleteAll()
            lastFailed = false
        } catch { lastFailed = true }
        updateCount()
    }

    private func kick() {
        guard worker == nil else { return }
        worker = Task(priority: .utility) { [weak self] in await self?.run() }
    }

    private func run() async {
        defer { worker = nil }
        while !Task.isCancelled {
            if dirty.isEmpty && operations.isEmpty { isPaused = false; return }
            if backfillBusy {
                isPaused = true
                try? await Task.sleep(for: pauseInterval)
                continue
            }
            isPaused = false
            if !dirty.isEmpty {
                if debounce > .zero { try? await Task.sleep(for: debounce) }
                guard !Task.isCancelled, !dirty.isEmpty else { continue }
                reconcile(dirty.removeFirst())
            } else {
                await apply(operations.removeFirst())
            }
            await Task.yield()
        }
    }

    func settle() async {
        while let worker { await worker.value }
    }

    var pendingOperations: Int { operations.count + dirty.count }

    private func reconcile(_ account: AccountID) {
        guard let rows = latest[account] else { return }
        let labels = names[account] ?? [:]
        var present: [String: SpotlightItem] = [:]
        for row in rows {
            let item = SpotlightItemBuilder.item(for: row, labelNames: labels, includeSubjects: includesSubjects)
            present[item.identifier] = item
        }
        var known = sent[account] ?? [:]
        let remembered = Set(defaults.stringArray(forKey: Self.ledgerKey(account)) ?? [])
        let stale = Set(known.keys).union(remembered).subtracting(present.keys).sorted()
        let changed = present.values.filter { known[$0.identifier] != $0.hashValue }.sorted { $0.date > $1.date }
        for id in stale { known[id] = nil }
        for item in changed { known[item.identifier] = item.hashValue }
        sent[account] = known
        defaults.set(present.keys.sorted(), forKey: Self.ledgerKey(account))
        for chunk in Self.chunks(stale, size: batchSize) { operations.append(.delete(account, chunk)) }
        for chunk in Self.chunks(changed, size: batchSize) { operations.append(.upsert(account, chunk)) }
        updateCount()
    }

    private func apply(_ operation: Operation) async {
        do {
            switch operation {
            case .upsert(_, let items): try await index.index(items)
            case .delete(_, let ids): try await index.delete(identifiers: ids)
            case .deleteDomain(let account): try await index.delete(domains: [SpotlightIdentifier.domain(account)])
            }
            lastFailed = false
        } catch {
            lastFailed = true
            if case .upsert(let account, let items) = operation {
                for item in items { sent[account]?[item.identifier] = nil }
                updateCount()
            }
        }
    }

    private func updateCount() { indexedCount = sent.values.reduce(0) { $0 + $1.count } }

    static func chunks<T>(_ values: [T], size: Int) -> [[T]] {
        let size = max(1, size)
        return stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) }
    }
}
