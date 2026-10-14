import CryptoKit
import Foundation
import OpenHumanAI
import OpenHumanCore
import Synchronization

public final class SemanticProgressBroadcaster: Sendable {
    private struct State {
        var latest: SemanticIndexProgress
        var subscribers: [UUID: AsyncStream<SemanticIndexProgress>.Continuation] = [:]
    }
    private let state: Mutex<State>

    public init(_ initial: SemanticIndexProgress = SemanticIndexProgress(phase: .off(.disabled))) {
        state = Mutex(State(latest: initial))
    }

    public var latest: SemanticIndexProgress { state.withLock { $0.latest } }

    public func publish(_ progress: SemanticIndexProgress) {
        let subscribers = state.withLock { s -> [AsyncStream<SemanticIndexProgress>.Continuation] in
            s.latest = progress
            return Array(s.subscribers.values)
        }
        for subscriber in subscribers { subscriber.yield(progress) }
    }

    public func updates() -> AsyncStream<SemanticIndexProgress> {
        let (stream, continuation) = AsyncStream.makeStream(of: SemanticIndexProgress.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let latest = state.withLock { s -> SemanticIndexProgress in
            s.subscribers[id] = continuation
            return s.latest
        }
        continuation.yield(latest)
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }
}

public actor SemanticIndexer {
    public struct Configuration: Sendable {
        public var batchSize = 32
        public var scanLimit = 500
        public var passInterval: Duration = .seconds(60)
        public var nudgeStep: Duration = .seconds(10)
        public var pauseRecheck: Duration = .seconds(5)
        public var youngMail: TimeInterval = 2 * 86_400
        public var reconcileEvery: TimeInterval = 86_400
        public init() {}
    }

    private let index: SemanticIndex
    private let source: any SemanticCorpusSource
    private let provider: any TextEmbeddingProvider
    private let gate: any IndexingGate
    private let clock: any OHClock
    private let configuration: Configuration
    public nonisolated let progress: SemanticProgressBroadcaster
    private var loop: Task<Void, Never>?
    private var nudged = false
    private var prepared = false
    private var requeue: [Int64] = []
    private var needsReconcile = false
    private var lastPendingPass: Date?
    private var eligible: (count: Int, at: Date)?

    public init(index: SemanticIndex, source: any SemanticCorpusSource, provider: any TextEmbeddingProvider,
                gate: any IndexingGate = OpenIndexingGate(), clock: any OHClock = SystemClock(),
                configuration: Configuration = Configuration(), progress: SemanticProgressBroadcaster = SemanticProgressBroadcaster()) {
        self.index = index
        self.source = source
        self.provider = provider
        self.gate = gate
        self.clock = clock
        self.configuration = configuration
        self.progress = progress
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public var isRunning: Bool { loop != nil }

    public func nudge() { nudged = true }

    public func requestReconciliation() { needsReconcile = true }

    private func run() async {
        await provider.prewarm()
        while !Task.isCancelled {
            if let reason = await gate.pauseReason() {
                await publish(.paused(reason))
                do { try await clock.sleep(for: configuration.pauseRecheck) } catch { break }
                continue
            }
            do {
                if try await runRound() { continue }
                try await idle()
            } catch is CancellationError {
                break
            } catch {
                publishFailure(error)
                do { try await clock.sleep(for: configuration.passInterval) } catch { break }
            }
        }
    }

    private func idle() async throws {
        var waited: Duration = .zero
        while waited < configuration.passInterval, !nudged {
            try await clock.sleep(for: configuration.nudgeStep)
            waited += configuration.nudgeStep
        }
    }

    @discardableResult
    public func runRound() async throws -> Bool {
        nudged = false
        if !prepared {
            try await prepare()
            prepared = true
        }
        var worked = false
        if !requeue.isEmpty {
            let ids = requeue
            requeue = []
            try await embed(try await source.messages(ids).filter(\.isEligible))
            worked = true
        }
        if try await newMessagesPass() { worked = true }
        if lastPendingPass.map({ clock.now.timeIntervalSince($0) >= configuration.passInterval.timeInterval }) ?? true {
            lastPendingPass = clock.now
            if try await pendingBodiesPass() { worked = true }
        }
        if try await reconciliationDue() { try await reconcile() }
        await publish(worked ? .indexing : .ready)
        return worked
    }

    public func prepare() async throws {
        let epoch = try await source.storeEpoch()
        if let known = try await index.storeEpoch(), known != epoch { try await index.reset() }
        try await index.setStoreEpoch(epoch)
        let space = try await provider.space()
        if let active = await index.activeSpace, active.id != space.id {
            if try await sameVectors(active, space) {
                try await index.adopt(space)
            } else {
                try await index.reset()
            }
        }
        if await index.activeSpace == nil {
            let probes = try await provider.embed(EmbeddingProbe.sentences, role: .document)
            try await index.activate(space, probes: probes, now: clock.now)
        }
        if !index.openedAfterCleanShutdown {
            requeue += try await index.verifyRecentSlots(since: clock.now.addingTimeInterval(-86_400))
            needsReconcile = true
        }
    }

    private func sameVectors(_ active: EmbeddingSpace, _ space: EmbeddingSpace) async throws -> Bool {
        guard active.providerID == space.providerID, active.dimension == space.dimension, active.recipe == space.recipe,
              active.queryPrefix == space.queryPrefix, active.documentPrefix == space.documentPrefix,
              let stored = await index.probes() else { return false }
        let fresh = try await provider.embed(EmbeddingProbe.sentences, role: .document)
        return EmbeddingProbe.matches(stored, fresh)
    }

    func newMessagesPass() async throws -> Bool {
        let batch = try await source.messages(after: try await index.watermark(), limit: configuration.scanLimit)
        guard let last = batch.last else { return false }
        var statuses: [Int64: CorpusBodyDownload] = [:]
        var ready: [CorpusMessage] = []
        var pending: [(mid: Int64, account: Int64)] = []
        for message in batch where message.isEligible {
            if message.bodyState >= 2 {
                ready.append(message)
                continue
            }
            let status: CorpusBodyDownload
            if let known = statuses[message.account] {
                status = known
            } else {
                status = try await source.bodyDownload(account: message.account)
                statuses[message.account] = status
            }
            if status != .downloading {
                ready.append(message)
            } else {
                pending.append((message.mid, message.account))
                if clock.now.timeIntervalSince(message.internalDate) < configuration.youngMail { ready.append(message) }
            }
        }
        try await index.addPending(pending, now: clock.now)
        try await embed(ready)
        try await index.setWatermark(last.mid, now: clock.now)
        return true
    }

    func pendingBodiesPass() async throws -> Bool {
        var worked = false
        for (account, mids) in try await index.pendingByAccount() {
            let status = try await source.bodyDownload(account: account)
            var ready = mids
            if status == .downloading {
                let awaiting = try await source.awaitingBodies(account: account)
                ready = mids.filter { !awaiting.contains($0) }
            }
            for chunk in Self.chunks(ready, of: configuration.scanLimit) {
                try await embed(try await source.messages(chunk).filter(\.isEligible))
                try await index.removePending(chunk)
                worked = true
            }
        }
        return worked
    }

    private func reconciliationDue() async throws -> Bool {
        if needsReconcile { return true }
        guard let last = try await index.reconciledAt() else {
            try await index.setReconciled(clock.now)
            return false
        }
        return clock.now.timeIntervalSince(last) >= configuration.reconcileEvery
    }

    func reconcile() async throws {
        needsReconcile = false
        for chunk in Self.chunks(await index.mids(), of: configuration.scanLimit) {
            let identities = try await source.identities(chunk)
            var gone: [Int64] = []
            for mid in chunk {
                guard let entry = await index.entry(mid: mid) else { continue }
                if let identity = identities[mid] {
                    if identity != entry.gmailID {
                        gone.append(mid)
                        requeue.append(mid)
                    }
                } else {
                    gone.append(mid)
                }
            }
            try await index.remove(mids: gone)
        }
        try await index.setReconciled(clock.now)
    }

    func embed(_ messages: [CorpusMessage]) async throws {
        guard let space = await index.activeSpace, !messages.isEmpty else { return }
        let size = max(1, min(configuration.batchSize, provider.preferredBatchSize))
        let provider = self.provider
        for start in Swift.stride(from: 0, to: messages.count, by: size) {
            try Task.checkCancellation()
            while let reason = await gate.pauseReason() {
                await publish(.paused(reason))
                try await clock.sleep(for: configuration.pauseRecheck)
            }
            let began = clock.now
            let chunk = Array(messages[start..<min(start + size, messages.count)])
            let documents = Dictionary(try await source.documents(chunk.map(\.mid)).map { ($0.mid, $0) },
                                       uniquingKeysWith: { first, _ in first })
            var texts: [String] = []
            var entries: [SemanticIndex.Entry] = []
            for message in chunk {
                guard let document = documents[message.mid] else { continue }
                let recipe = EmbeddingRecipe.document(document.text)
                let digest = Self.digest(recipe)
                if let existing = await index.entry(mid: message.mid), existing.digest == digest,
                   existing.gmailID == message.gmailID { continue }
                texts.append(await EmbeddingRecipe.fit(recipe, prefix: space.documentPrefix, maxTokens: space.maxInputTokens,
                                                       count: { await provider.countTokens($0) }))
                entries.append(SemanticIndex.Entry(mid: message.mid, account: message.account, thread: message.thread,
                                                   gmailID: message.gmailID, internalDate: message.internalDate,
                                                   source: document.hasStoredBody ? 2 : 1, digest: digest))
            }
            guard !texts.isEmpty else { continue }
            let vectors: [[Float]]
            do {
                vectors = try await provider.embed(texts, role: .document)
                guard vectors.count == entries.count else { throw AIError.invalidOutput("vector count") }
            } catch AIError.cancelled {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                try await index.addFailed(entries.count)
                continue
            }
            try await index.upsert(zip(entries, vectors).map { (entry: $0.0, vector: $0.1) }, now: clock.now)
            await publish(.indexing)
            let rest = Self.rest(afterBusy: clock.now.timeIntervalSince(began), duty: await gate.dutyShare())
            if rest > 0 { try await clock.sleep(for: .milliseconds(Int64((rest * 1000).rounded(.up)))) }
        }
    }

    public static func rest(afterBusy busy: TimeInterval, duty: Double) -> TimeInterval {
        let share = min(max(duty, 0.05), 1)
        return max(0, busy) * (1 / share - 1)
    }

    static func digest(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8)).prefix(16)) }

    static func chunks(_ ids: [Int64], of size: Int) -> [[Int64]] {
        Swift.stride(from: 0, to: ids.count, by: max(1, size)).map { Array(ids[$0..<min($0 + max(1, size), ids.count)]) }
    }

    private func publish(_ phase: SemanticIndexProgress.Phase) async {
        let embedded = await index.count
        let bytes = await index.bytesOnDisk
        let spaceID = await index.activeSpace?.id
        let failed = (try? await index.failedCount()) ?? 0
        progress.publish(SemanticIndexProgress(phase: phase, embedded: embedded, eligible: await eligibleCount(),
                                               bytesOnDisk: bytes, spaceID: spaceID, failed: failed))
    }

    private func publishFailure(_ error: any Error) {
        var latest = progress.latest
        latest.phase = .failed(Self.code(error))
        progress.publish(latest)
    }

    private func eligibleCount() async -> Int {
        if let eligible, clock.now.timeIntervalSince(eligible.at) < 60 { return eligible.count }
        var total = 0
        for account in (try? await source.accounts()) ?? [] { total += (try? await source.eligibleCount(account: account)) ?? 0 }
        eligible = (total, clock.now)
        return total
    }

    static func code(_ error: any Error) -> String {
        switch error {
        case is SidecarError: return "index"
        case is AIError: return "model"
        default: return "source"
        }
    }
}
