import Foundation
import MailFeatures
import OpenHumanAI
import OpenHumanAIMLX
import OpenHumanAIMLXRuntime
import OpenHumanAIModelStore
import Synchronization

final class ClassifierServices: LocalClassifierModelPort, Sendable {
    @MainActor static var current: ClassifierServices?

    private let registry: ProviderRegistry
    private let settings: AISettingsBox
    private let service: Mutex<LocalClassifierService>

    @MainActor @discardableResult
    static func install(registry: ProviderRegistry, settings: AISettingsBox) -> ClassifierServices {
        let services = ClassifierServices(registry: registry, settings: settings)
        current = services
        return services
    }

    private init(registry: ProviderRegistry, settings: AISettingsBox) {
        self.registry = registry
        self.settings = settings
        let made = Self.makeService(settings: settings)
        self.service = Mutex(made)
        registry.register(classifier: made.classifier)
        made.provider.startMonitoringMemoryPressure()
    }

    private static func makeService(settings: AISettingsBox) -> LocalClassifierService {
        let root = settings.current.modelsDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ModelStore.defaultRoot
        return LocalClassifierService(
            manifest: LocalClassifierModels.defaultModel, rootDirectory: root, runtime: MLXLocalModelRuntime(),
            allowsLoading: { settings.current.enabled && settings.current.classifier != .appleModel },
            gate: LocalClassifierGate(allowsLowPowerMode: { settings.current.localClassifierInLowPowerMode }))
    }

    private var currentService: LocalClassifierService { service.withLock { $0 } }

    var modelName: String { LocalClassifierModels.defaultModel.displayName }
    var sizeBytes: Int64 { LocalClassifierModels.defaultModel.totalBytes }
    var licence: String { LocalClassifierModels.defaultModel.license }

    func directoryPath() async -> String { currentService.rootDirectory.path }

    func status() async -> LocalModelStatus { Self.status(await currentService.state()) }

    func download(confirmedSizeBytes: Int64) async -> AsyncStream<LocalModelStatus> {
        let service = currentService
        let states = await service.download(confirmedSizeBytes: confirmedSizeBytes)
        return AsyncStream { continuation in
            let task = Task {
                for await state in states {
                    let partial = await service.partialBytes()
                    continuation.yield(Self.status(LocalClassifierService.state(state, partial: partial)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancel() async { await currentService.cancel() }

    func delete() async throws { try await currentService.delete() }

    func useDirectory(_ path: String?) async throws {
        if let path {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isWritableFile(atPath: path) else {
                throw ModelStoreError.transport("folder")
            }
        }
        let old = currentService
        await old.provider.unload()
        _ = try? settings.update { $0.modelsDirectory = path }
        let made = Self.makeService(settings: settings)
        service.withLock { $0 = made }
        registry.register(classifier: made.classifier)
        made.provider.startMonitoringMemoryPressure()
    }

    static func status(_ state: LocalClassifierService.State) -> LocalModelStatus {
        switch state {
        case .notDownloaded(let partial): .notDownloaded(partialBytes: partial)
        case .downloading(let progress): .downloading(bytesDone: progress.bytesDone, bytesTotal: progress.bytesTotal)
        case .verifying: .verifying
        case .ready: .ready
        case .failed(let why): .failed(why)
        }
    }
}
