import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

final class FakeClassifierModelPort: LocalClassifierModelPort, Sendable {
    let modelName = "Tiny model"
    let sizeBytes: Int64 = 980_000_000
    let licence = "Apache-2.0"
    private let state = Mutex<(status: LocalModelStatus, downloads: [Int64], directory: String, cancels: Int)>(
        (.notDownloaded(partialBytes: 0), [], "/default/models", 0))

    var downloads: [Int64] { state.withLock { $0.downloads } }
    var cancels: Int { state.withLock { $0.cancels } }

    func directoryPath() async -> String { state.withLock { $0.directory } }
    func status() async -> LocalModelStatus { state.withLock { $0.status } }
    func download(confirmedSizeBytes: Int64) async -> AsyncStream<LocalModelStatus> {
        state.withLock { $0.downloads.append(confirmedSizeBytes) }
        let ok = confirmedSizeBytes == sizeBytes
        let final: LocalModelStatus = ok ? .ready : .failed("The download needs your confirmation.")
        state.withLock { $0.status = final }
        return AsyncStream { continuation in
            if ok {
                continuation.yield(.downloading(bytesDone: 490_000_000, bytesTotal: sizeBytes))
                continuation.yield(.verifying)
            }
            continuation.yield(final)
            continuation.finish()
        }
    }
    func cancel() async { state.withLock { $0.cancels += 1 } }
    func delete() async throws { state.withLock { $0.status = .notDownloaded(partialBytes: 0) } }
    func useDirectory(_ path: String?) async throws { state.withLock { $0.directory = path ?? "/default/models" } }
}

@MainActor
@Suite struct ClassifierSettingsTests {
    private func center(_ settings: AISettings = AISettings(), classifiers: [any AIClassificationProvider] = []) -> AICenter {
        AICenter.make(registry: ProviderRegistry(classifiers: classifiers),
                      settings: AISettingsBox(store: InMemoryAISettingsStore(settings)))
    }

    @Test func nothingDownloadsBeforeTheClickAndTheClickPassesTheShownSize() async {
        let port = FakeClassifierModelPort()
        let model = ClassifierSettingsModel(center: center(), port: port)
        await model.refresh()
        #expect(model.downloadTitle == "Download classifier model (about 1 GB)")
        #expect(model.statusText == "Not downloaded. Nothing is downloaded until you click.")
        #expect(model.directory == "/default/models")
        #expect(port.downloads.isEmpty)
        let changed = Mutex(0)
        model.onChange = { changed.withLock { $0 += 1 } }
        model.download()
        await eventually { model.isReady }
        #expect(port.downloads == [port.sizeBytes])
        #expect(model.statusText.hasPrefix("Downloaded."))
        await eventually { changed.withLock { $0 } == 1 }
        await model.delete()
        #expect(model.status == .notDownloaded(partialBytes: 0))
    }

    @Test func wordsForProgressAResumableStopAndFailures() {
        let model = ClassifierSettingsModel(center: center(), port: FakeClassifierModelPort())
        #expect(ClassifierSettingsModel.sizeText(979_503_801) == "about 1 GB")
        #expect(ClassifierSettingsModel.sizeText(2_400_000_000) == "about 2.4 GB")
        #expect(ClassifierSettingsModel.sizeText(300_000_000) == "about 300 MB")
        #expect(ClassifierSettingsModel(center: center(), port: nil).canDownload == false)
        #expect(ClassifierPreference.allCases == [.appleModel, .localModel], "no Automatic choice")
    }

    @Test func theChoiceAndTheLowPowerSwitchAreSavedAndTheFolderIsKept() async {
        let ai = center()
        let port = FakeClassifierModelPort()
        let model = ClassifierSettingsModel(center: ai, port: port)
        let changed = Mutex(0)
        model.onChange = { changed.withLock { $0 += 1 } }
        model.preference = .localModel
        model.allowLowPower = true
        #expect(ai.settings.classifier == .localModel)
        #expect(ai.settings.localClassifierInLowPowerMode)
        await model.useDirectory("/Volumes/External/Models")
        #expect(ai.settings.modelsDirectory == "/Volumes/External/Models")
        #expect(model.directory == "/Volumes/External/Models")
        await eventually { changed.withLock { $0 } >= 2 }
    }

    @Test func theAutoLabelCenterFollowsTheChoice() async {
        let apple = FakeClassifier(id: "apple.system.classifier", displayName: "Apple")
        let appleOff = FakeClassifier(id: "apple.system.classifier", displayName: "Apple",
                                      availability: .unavailable(reason: .appleIntelligenceNotEnabled))
        let local = FakeClassifier(id: "local.qwen3-1.7b-4bit.classifier", displayName: "Downloaded")
        let localMissing = FakeClassifier(id: "local.qwen3-1.7b-4bit.classifier", displayName: "Downloaded",
                                          availability: .unavailable(reason: .modelNotDownloaded(sizeBytes: 1)))

        var picked = await AutoLabelCenter.onDeviceClassifier(center(classifiers: [local, apple])).0
        #expect(picked?.id == apple.id)
        picked = await AutoLabelCenter.onDeviceClassifier(center(classifiers: [local, appleOff])).0
        #expect(picked == nil, "Apple's model is the default and the downloaded one is never tried on its own")
        picked = await AutoLabelCenter.onDeviceClassifier(
            center(AISettings(classifier: .appleModel), classifiers: [local, appleOff])).0
        #expect(picked == nil)
        picked = await AutoLabelCenter.onDeviceClassifier(
            center(AISettings(classifier: .localModel), classifiers: [localMissing, apple])).0
        #expect(picked == nil)
        picked = await AutoLabelCenter.onDeviceClassifier(
            center(AISettings(classifier: .localModel), classifiers: [local, apple])).0
        #expect(picked?.id == local.id)
    }
}
