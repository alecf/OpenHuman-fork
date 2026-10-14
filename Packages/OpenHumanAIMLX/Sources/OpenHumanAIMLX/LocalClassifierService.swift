import Foundation
import OpenHumanAI
import OpenHumanAIModelStore

public final class LocalClassifierService: Sendable {
    public let manifest: ModelManifest
    public let rootDirectory: URL
    public let store: ModelStore
    public let provider: LocalModelProvider
    public let classifier: PromptedClassifier

    public enum State: Sendable, Hashable {
        case notDownloaded(partialBytes: Int64)
        case downloading(DownloadProgress)
        case verifying
        case ready
        case failed(String)
    }

    public init(manifest: ModelManifest = LocalClassifierModels.defaultModel, rootDirectory: URL = ModelStore.defaultRoot,
                runtime: any LocalModelRuntime, transport: any DownloadTransport = URLSessionDownloadTransport(),
                freeSpace: @escaping @Sendable (URL) throws -> Int64 = ModelStore.systemFreeSpace,
                allowsLoading: @escaping @Sendable () -> Bool, gate: LocalClassifierGate) {
        self.manifest = manifest
        self.rootDirectory = rootDirectory
        self.store = ModelStore(rootDirectory: rootDirectory, transport: transport, freeSpace: freeSpace)
        self.provider = LocalModelProvider(manifest: manifest, store: store, runtime: runtime,
                                           allowsModelLoading: allowsLoading)
        self.classifier = PromptedClassifier(
            wrapping: provider, id: AIProviderID(LocalClassifierModels.classifierID(for: manifest)),
            displayName: "Downloaded model (\(manifest.displayName))", gate: gate)!
    }

    public var sizeBytes: Int64 { manifest.totalBytes }

    public func state() async -> State {
        Self.state(await store.state(for: manifest), partial: await partialBytes())
    }

    public func partialBytes() async -> Int64 {
        guard await store.installedDirectory(for: manifest) == nil else { return 0 }
        return manifest.totalBytes - (await store.remainingBytes(for: manifest))
    }

    public func download(confirmedSizeBytes: Int64) async -> AsyncStream<DownloadState> {
        await store.download(manifest, confirmedSizeBytes: confirmedSizeBytes)
    }

    public func cancel() async { await store.cancel(manifest) }

    public func delete() async throws {
        await provider.unload()
        try await store.delete(manifest)
    }

    public func updates() async -> AsyncStream<DownloadState> { await store.updates(for: manifest) }

    public static func state(_ download: DownloadState, partial: Int64) -> State {
        switch download {
        case .idle, .cancelled: return .notDownloaded(partialBytes: max(0, partial))
        case .downloading(let progress): return .downloading(progress)
        case .verifying: return .verifying
        case .ready: return .ready
        case .failed(let error): return .failed(failureText(error))
        }
    }

    public static func failureText(_ error: ModelStoreError) -> String {
        switch error {
        case .checksumMismatch, .sizeMismatch:
            return "The download was damaged and was removed. Try again."
        case .insufficientDiskSpace:
            return "Not enough free space for the model. Free some space or choose another folder."
        case .sizeNotConfirmed:
            return "The download needs your confirmation."
        case .tooLarge:
            return "The model is larger than expected and was not downloaded."
        case .transport:
            return "The download stopped. Try again to resume it."
        case .alreadyDownloading:
            return "The model is already downloading."
        case .invalidManifest, .notInstalled:
            return "This model can't be downloaded."
        }
    }
}
