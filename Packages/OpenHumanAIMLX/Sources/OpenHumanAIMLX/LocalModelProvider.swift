import Dispatch
import Foundation
import OpenHumanAI
import OpenHumanAIModelStore
import Synchronization

public final class LocalModelProvider: AIProvider {
    public let manifest: ModelManifest
    private let store: ModelStore
    private let allowsModelLoading: @Sendable () -> Bool
    private let holder: SessionHolder
    private let pressure = Mutex<DispatchSourceMemoryPressure?>(nil)

    public init(
        manifest: ModelManifest, store: ModelStore, runtime: any LocalModelRuntime = UnlinkedLocalModelRuntime(),
        allowsModelLoading: @escaping @Sendable () -> Bool = { false }, idleTimeout: Duration = .seconds(600)
    ) {
        self.manifest = manifest
        self.store = store
        self.allowsModelLoading = allowsModelLoading
        self.holder = SessionHolder(runtime: runtime, manifest: manifest, idleTimeout: idleTimeout)
    }

    deinit { pressure.withLock { $0?.cancel() } }

    public var id: AIProviderID { .local(manifest.id) }
    public var displayName: String { manifest.displayName }

    public func availability() async -> AIAvailability {
        switch await store.state(for: manifest) {
        case .ready:
            return allowsModelLoading() ? .available : .unavailable(reason: .disabledBySettings)
        case .downloading(let progress):
            return .unavailable(reason: .downloading(progress: progress.fraction))
        case .verifying:
            return .unavailable(reason: .downloading(progress: 1))
        case .idle, .failed, .cancelled:
            return .unavailable(reason: .modelNotDownloaded(sizeBytes: manifest.totalBytes))
        }
    }

    public func capabilities() async -> AICapabilities {
        let loaded = await holder.loadedContextSize
        return AICapabilities(
            contextTokens: loaded ?? manifest.declaredContextTokens, policyInputCap: nil,
            tokenCounting: await holder.hasTokenizer ? .exact : .heuristic, streaming: true,
            structuredOutput: .promptedJSON, dataLocation: .onDevice, typicalLatency: .interactive)
    }

    public func countTokens(_ text: String) async -> Int {
        if let count = await holder.countTokens(text) { return count }
        return TokenHeuristic.count(text)
    }

    public func modelVersion() async -> String? { "\(manifest.id)@\(manifest.revision)" }

    public func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let availability = await availability()
                    guard availability.isAvailable else {
                        throw AIError.unavailable(availability.unavailableReason ?? .other("Unavailable"))
                    }
                    guard let directory = await store.installedDirectory(for: manifest) else {
                        throw AIError.unavailable(.modelNotDownloaded(sizeBytes: manifest.totalBytes))
                    }
                    let session = try await holder.begin(directory: directory)
                    defer { Task { await holder.end() } }
                    continuation.yield(.started(providerID: id, model: manifest.id))
                    let stream = session.generate(
                        system: request.system, input: request.renderedInput(), maxTokens: request.output.maxTokens,
                        temperature: request.temperature)
                    for try await piece in stream where !piece.isEmpty { continuation.yield(.textDelta(piece)) }
                    continuation.yield(.finished(usage: nil))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AIError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func unload() async { await holder.unload() }

    public func handleMemoryPressure() async { await holder.unload() }

    public var isLoaded: Bool { get async { await holder.isLoaded } }

    public func startMonitoringMemoryPressure() {
        pressure.withLock { source in
            guard source == nil else { return }
            let created = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
            created.setEventHandler { [weak self] in
                guard let self else { return }
                Task { await self.handleMemoryPressure() }
            }
            created.resume()
            source = created
        }
    }
}

actor SessionHolder {
    private let runtime: any LocalModelRuntime
    private let manifest: ModelManifest
    private let idleTimeout: Duration
    private var session: (any LocalModelSession)?
    private var loading: Task<any LocalModelSession, Error>?
    private var inUse = 0
    private var idleTask: Task<Void, Never>?
    private var generation = 0

    init(runtime: any LocalModelRuntime, manifest: ModelManifest, idleTimeout: Duration) {
        self.runtime = runtime
        self.manifest = manifest
        self.idleTimeout = idleTimeout
    }

    var isLoaded: Bool { session != nil }
    var loadedContextSize: Int? { session?.contextSize }
    var hasTokenizer: Bool { session != nil }

    func countTokens(_ text: String) async -> Int? { await session?.countTokens(text) }

    func begin(directory: URL) async throws -> any LocalModelSession {
        idleTask?.cancel()
        idleTask = nil
        inUse += 1
        do {
            if let session { return session }
            let task = loading ?? Task { [runtime, manifest] in try await runtime.load(modelDirectory: directory, manifest: manifest) }
            loading = task
            let loaded = try await task.value
            loading = nil
            session = loaded
            return loaded
        } catch {
            inUse -= 1
            loading = nil
            throw error
        }
    }

    func end() {
        inUse = max(0, inUse - 1)
        guard inUse == 0, session != nil else { return }
        generation += 1
        let expected = generation
        idleTask?.cancel()
        idleTask = Task { [idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            await self.unloadIfIdle(generation: expected)
        }
    }

    private func unloadIfIdle(generation expected: Int) async {
        guard expected == generation, inUse == 0 else { return }
        await unload()
    }

    func unload() async {
        idleTask?.cancel()
        idleTask = nil
        let current = session
        session = nil
        await current?.unload()
    }
}
