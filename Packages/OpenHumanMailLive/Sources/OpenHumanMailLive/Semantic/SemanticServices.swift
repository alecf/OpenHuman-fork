import Foundation
import MailFeatures
import MailModel
import OpenHumanAI
import OpenHumanAIApple
import OpenHumanCore
import OpenHumanSemanticIndex
import OpenHumanStore
import Synchronization

public struct SemanticSearchArm: Sendable {
    public var firstPaintBudget: Duration
    let candidates: @Sendable (SearchQuery, [AccountID]) async -> ExternalSearchCandidates?
    let cached: @Sendable (SearchQuery, [AccountID]) -> ExternalSearchCandidates?
    let noteActivity: @Sendable () -> Void
    let status: @Sendable () -> AsyncStream<SmartSearchStatus>

    public init(firstPaintBudget: Duration = .milliseconds(150),
                candidates: @escaping @Sendable (SearchQuery, [AccountID]) async -> ExternalSearchCandidates?,
                cached: @escaping @Sendable (SearchQuery, [AccountID]) -> ExternalSearchCandidates? = { _, _ in nil },
                noteActivity: @escaping @Sendable () -> Void = {},
                status: @escaping @Sendable () -> AsyncStream<SmartSearchStatus> = { AsyncStream { $0.finish() } }) {
        self.firstPaintBudget = firstPaintBudget
        self.candidates = candidates
        self.cached = cached
        self.noteActivity = noteActivity
        self.status = status
    }

    static func plan(_ query: SearchQuery) -> (text: String, after: Date?, before: Date?, structured: Bool)? {
        let quoted = quotedPhrases(query.text)
        var words: [String] = []
        var after: Date?, before: Date?
        var structured = false
        for term in query.terms {
            switch term {
            case let .text(text, field) where field == nil:
                if !quoted.contains(text.lowercased()) { words.append(text) }
            case .after(let date): after = max(after ?? date, date)
            case .before(let date): before = min(before ?? date, date)
            case .rfc822msgid: return nil
            default: structured = true
            }
        }
        guard words.contains(where: { $0.count >= 3 }) else { return nil }
        return (EmbeddingRecipe.query(words), after, before, structured)
    }

    static func quotedPhrases(_ text: String) -> Set<String> {
        let parts = text.split(separator: "\"", omittingEmptySubsequences: false)
        return Set(Swift.stride(from: 1, to: parts.count, by: 2).map { parts[$0].trimmingCharacters(in: .whitespaces).lowercased() })
    }
}

struct StoreSemanticSource: SemanticCorpusSource {
    let store: any SemanticIndexReading & MailReading

    func storeEpoch() async throws -> String { try store.storeEpoch() }
    func accounts() async throws -> [Int64] { try store.accounts().map(\.id.rawValue) }

    func messages(after mid: Int64, limit: Int) async throws -> [CorpusMessage] {
        try store.indexableMessages(afterMessage: mid > 0 ? MessageRowID(rawValue: mid) : nil, limit: limit).map(Self.corpus)
    }

    func messages(_ mids: [Int64]) async throws -> [CorpusMessage] {
        try store.indexableMessages(mids.map { MessageRowID(rawValue: $0) }).map(Self.corpus)
    }

    func awaitingBodies(account: Int64) async throws -> Set<Int64> {
        Set(try store.messageIDsAwaitingBodies(account: AccountID(account)).map(\.rawValue))
    }

    func documents(_ mids: [Int64]) async throws -> [CorpusDocument] {
        try store.indexableDocuments(mids.map { MessageRowID(rawValue: $0) }).map { document in
            CorpusDocument(mid: document.message.rawValue,
                           text: EmbeddingRecipe.MessageText(subject: document.subject, senderName: document.fromName,
                                                             body: document.body, attachmentNames: document.attachmentNames),
                           hasStoredBody: document.hasStoredBody)
        }
    }

    func identities(_ mids: [Int64]) async throws -> [Int64: String] {
        var result: [Int64: String] = [:]
        for (mid, id) in try store.messageIdentities(mids.map { MessageRowID(rawValue: $0) }) { result[mid.rawValue] = id.rawValue }
        return result
    }

    func bodyDownload(account: Int64) async throws -> CorpusBodyDownload {
        CorpusBodyDownload(rawValue: try store.bodyDownloadStatus(account: AccountID(account)).rawValue) ?? .downloading
    }

    func eligibleCount(account: Int64) async throws -> Int { try store.indexableCount(account: AccountID(account)) }

    static func corpus(_ message: IndexableMessage) -> CorpusMessage {
        CorpusMessage(mid: message.message.rawValue, account: message.account.rawValue, gmailID: message.gmailMessageID.rawValue,
                      thread: message.thread.rawValue, internalDate: message.internalDate, bodyState: message.bodyState.rawValue,
                      isDraft: message.isDraft, inSpam: message.inSpam)
    }
}

final class AppIndexingGate: IndexingGate {
    private let lastActivity = Mutex<Date?>(nil)
    private let folder: URL?
    private let isAppActive: @MainActor @Sendable () -> Bool

    init(folder: URL?, isAppActive: @escaping @MainActor @Sendable () -> Bool = { PlatformServices.current.isAppActive() }) {
        self.folder = folder
        self.isAppActive = isAppActive
    }

    func noteActivity() { lastActivity.withLock { $0 = Date() } }

    func pauseReason() async -> SemanticIndexProgress.PauseReason? {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return .lowPower }
        if info.thermalState == .serious || info.thermalState == .critical { return .hot }
        if let last = lastActivity.withLock({ $0 }), Date().timeIntervalSince(last) < 3 { return .userActive }
        if let folder, let free = try? folder.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < 1_000_000_000 { return .lowDisk }
        return nil
    }

    func dutyShare() async -> Double { await MainActor.run { isAppActive() } ? 0.25 : 0.5 }
}

private final class CandidateCache: Sendable {
    private let entries = Mutex<[(key: String, value: ExternalSearchCandidates)]>([])

    static func key(_ query: SearchQuery, _ accounts: [AccountID]) -> String {
        query.text + "\u{1F}" + accounts.map { String($0.rawValue) }.sorted().joined(separator: ",")
    }

    func get(_ key: String) -> ExternalSearchCandidates? { entries.withLock { $0.first { $0.key == key }?.value } }

    func put(_ key: String, _ value: ExternalSearchCandidates) {
        entries.withLock { list in
            list.removeAll { $0.key == key }
            list.append((key, value))
            if list.count > 8 { list.removeFirst(list.count - 8) }
        }
    }

    func clear() { entries.withLock { $0.removeAll() } }
}

@MainActor
public final class SemanticServices {
    enum Storage: Equatable { case directory(URL), inMemory }

    private struct Runtime: Sendable {
        let index: SemanticIndex
        let provider: any TextEmbeddingProvider
    }

    private let store: any SemanticIndexReading & MailReading & MailObserving
    private let searching: any MailSearching
    private let storage: Storage
    private let ai: AICenter?
    private let makeProvider: @MainActor () -> (any TextEmbeddingProvider)?
    public static var current: SemanticServices?
    let progress = SemanticProgressBroadcaster()
    let gate: AppIndexingGate
    private let runtime = Mutex<Runtime?>(nil)
    private let cache = CandidateCache()
    private var indexer: SemanticIndexer?
    private var accountsTask: Task<Void, Never>?
    private var knownAccounts: Set<Int64> = []

    init?(store: Any, storage: Storage, ai: AICenter?, makeProvider: @escaping @MainActor () -> (any TextEmbeddingProvider)?) {
        guard let reading = store as? any SemanticIndexReading & MailReading & MailObserving,
              let searching = store as? any MailSearching else { return nil }
        self.store = reading
        self.searching = searching
        self.storage = storage
        self.ai = ai
        self.makeProvider = makeProvider
        if case .directory(let url) = storage { gate = AppIndexingGate(folder: url) } else { gate = AppIndexingGate(folder: nil) }
    }

    static func folder(storeDirectory: URL) -> URL {
        storeDirectory.appendingPathComponent(SemanticIndex.folderName, isDirectory: true)
    }

    nonisolated static func appleProvider(_ settings: SmartSearchSettings) -> (any TextEmbeddingProvider)? {
        let id = settings.providerID ?? EmbeddingProviders.evalChosenDefault ?? EmbeddingProviders.appleSentence
        let provider: any TextEmbeddingProvider
        switch id {
        case EmbeddingProviders.appleContextual: provider = NLContextualEmbeddingProvider()
        default: provider = NLSentenceEmbeddingProvider()
        }
        return EmbeddingProviders.onDeviceOnly(provider)
    }

    var isOn: Bool {
        guard let settings = ai?.settings, settings.enabled else { return false }
        return settings.smartSearch.indexingEnabled(defaultProviderNeedsDownload: false)
    }

    var indexSwitch: Bool { ai?.settings.smartSearch.enabled ?? false }

    func setIndexSwitch(_ on: Bool) {
        try? ai?.update { $0.smartSearch.enabled = on }
        Task { await self.apply() }
    }

    func apply() async {
        guard isOn else {
            await indexer?.stop()
            indexer = nil
            var latest = progress.latest
            latest.phase = .off(ai?.settings.enabled == false ? .aiOff : .disabled)
            progress.publish(latest)
            return
        }
        guard indexer == nil else { return }
        guard let provider = makeProvider(), await provider.availability().isAvailable else {
            progress.publish(SemanticIndexProgress(phase: .off(.noProvider)))
            return
        }
        do {
            let index = try existingIndex() ?? SemanticIndex(location: location)
            runtime.withLock { $0 = Runtime(index: index, provider: provider) }
            let indexer = SemanticIndexer(index: index, source: StoreSemanticSource(store: store), provider: provider,
                                          gate: gate, progress: progress)
            self.indexer = indexer
            await indexer.start()
            followAccounts()
            Log(.app).info("smart search index started")
        } catch {
            progress.publish(SemanticIndexProgress(phase: .failed("open")))
            Log(.app).notice("smart search index could not open (\(String(describing: type(of: error))))")
        }
    }

    func rebuild() async {
        cache.clear()
        await indexer?.stop()
        indexer = nil
        if let index = runtime.withLock({ $0?.index }) { try? await index.reset() }
        await apply()
    }

    func deleteIndex() async {
        try? ai?.update { $0.smartSearch.enabled = false }
        cache.clear()
        await indexer?.stop()
        indexer = nil
        accountsTask?.cancel()
        accountsTask = nil
        let index = runtime.withLock { current -> SemanticIndex? in
            defer { current = nil }
            return current?.index
        }
        if let index {
            try? await index.destroy()
        } else if case .directory(let folder) = storage {
            try? FileManager.default.removeItem(at: folder)
        }
        progress.publish(SemanticIndexProgress(phase: .off(.disabled)))
        Log(.app).info("smart search index deleted")
    }

    func nudge() { Task { await indexer?.nudge() } }

    func close() async {
        if let index = runtime.withLock({ $0?.index }) { await index.close() }
    }

    nonisolated var arm: SemanticSearchArm {
        SemanticSearchArm(candidates: { [weak self] query, accounts in await self?.candidates(query, accounts: accounts) },
                          cached: { [weak self] query, accounts in self?.cache.get(CandidateCache.key(query, accounts)) },
                          noteActivity: { [weak self] in self?.gate.noteActivity() },
                          status: { [weak self] in self?.statusUpdates() ?? AsyncStream { $0.finish() } })
    }

    nonisolated func statusUpdates() -> AsyncStream<SmartSearchStatus> {
        let source = progress.updates()
        return AsyncStream { continuation in
            let task = Task {
                var last: SmartSearchStatus?
                for await update in source {
                    let status = Self.status(update)
                    guard status != last else { continue }
                    last = status
                    continuation.yield(status)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated static func status(_ progress: SemanticIndexProgress) -> SmartSearchStatus {
        let fraction = (progress.fraction * 100).rounded(.down) / 100
        switch progress.phase {
        case .off, .failed:
            return .off
        case .ready:
            return .ready
        case .indexing:
            return SmartSearchStatus(phase: .indexing, fraction: fraction)
        case .rebuilding(let share):
            return SmartSearchStatus(phase: .indexing, fraction: (share * 100).rounded(.down) / 100)
        case .paused(.userActive):
            let complete = progress.eligible > 0 && progress.embedded >= progress.eligible
            return complete ? .ready : SmartSearchStatus(phase: .indexing, fraction: fraction)
        case .paused(.lowPower):
            return SmartSearchStatus(phase: .paused(.lowPower), fraction: fraction)
        case .paused(.hot):
            return SmartSearchStatus(phase: .paused(.hot), fraction: fraction)
        case .paused(.lowDisk):
            return SmartSearchStatus(phase: .paused(.lowDisk), fraction: fraction)
        }
    }

    nonisolated func candidates(_ query: SearchQuery, accounts: [AccountID]) async -> ExternalSearchCandidates? {
        guard let plan = SemanticSearchArm.plan(query), let runtime = runtime.withLock({ $0 }) else { return nil }
        let key = CandidateCache.key(query, accounts)
        if let known = cache.get(key) { return known }
        do {
            guard await runtime.index.count > 0, let active = await runtime.index.activeSpace,
                  try await runtime.provider.space().id == active.id else { return nil }
            let vector = try await runtime.provider.embed(plan.text, role: .query)
            var allow: Set<Int64>?
            if plan.structured, let found = try? searching.structuredMessageIDs(query, accounts: accounts, limit: 20_000),
               !found.capped {
                allow = Set(found.ids.map(\.rawValue))
            }
            let hits = await runtime.index.search(vector, filter: SemanticIndex.Filter(
                accounts: Set(accounts.map(\.rawValue)), after: plan.after, before: plan.before, allowList: allow))
            let result = ExternalSearchCandidates(source: .semantic, candidates: hits.map {
                ExternalSearchCandidate(message: MessageRowID(rawValue: $0.mid), gmailMessageID: GmailMessageID($0.gmailID),
                                        score: Double($0.score))
            })
            cache.put(key, result)
            return result
        } catch {
            Log(.app).notice("semantic arm skipped (\(String(describing: type(of: error))))")
            return nil
        }
    }

    private var location: SemanticIndex.Location {
        switch storage {
        case .directory(let url): .directory(url)
        case .inMemory: .inMemory
        }
    }

    private func existingIndex() -> SemanticIndex? { runtime.withLock { $0?.index } }

    private func followAccounts() {
        guard accountsTask == nil else { return }
        let stream = store.observeAccounts().values()
        accountsTask = Task { [weak self] in
            do {
                for try await accounts in stream {
                    guard let self else { return }
                    let ids = Set(accounts.map(\.id.rawValue))
                    let removed = self.knownAccounts.subtracting(ids)
                    self.knownAccounts = ids
                    guard !removed.isEmpty, let index = self.runtime.withLock({ $0?.index }) else { continue }
                    self.cache.clear()
                    for account in removed { try? await index.removeAccount(account) }
                    Log(.app).info("smart search index: \(removed.count) account(s) removed")
                }
            } catch {}
        }
    }
}
