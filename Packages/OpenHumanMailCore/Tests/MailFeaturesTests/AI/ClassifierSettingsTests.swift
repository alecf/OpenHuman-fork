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
    private struct State {
        var status: LocalModelStatus = .notDownloaded(partialBytes: 0)
        var downloads: [Int64] = []
        var directory = "/default/models"
        var cancels = 0
        var leftovers: [LeftoverLocalModel] = []
        var deletedLeftovers: [String] = []
    }

    let modelName = "Qwen3.5 9B OptiQ (4-bit)"
    let classifierID: AIProviderID = "local.qwen3.5-9b-optiq-4bit.classifier"
    let sizeBytes: Int64 = 7_120_910_361
    let memoryBytes: Int64 = 7_973_397_524
    let licence = "Apache-2.0"
    let unsupportedReason: String?
    private let state: Mutex<State>

    init(unsupportedReason: String? = nil, leftovers: [LeftoverLocalModel] = []) {
        self.unsupportedReason = unsupportedReason
        state = Mutex(State(leftovers: leftovers))
    }

    var downloads: [Int64] { state.withLock { $0.downloads } }
    var cancels: Int { state.withLock { $0.cancels } }
    var deletedLeftovers: [String] { state.withLock { $0.deletedLeftovers } }

    func leftoverModels() async -> [LeftoverLocalModel] { state.withLock { $0.leftovers } }
    func deleteLeftover(id: String) async throws {
        state.withLock { state in
            state.deletedLeftovers.append(id)
            state.leftovers.removeAll { $0.id == id }
        }
    }

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
        #expect(model.downloadTitle == "Download classifier model (about 7.1 GB)")
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
        #expect(ai.settings.classifier == .localModel && ai.settings.selectedLocalModel == "qwen3.5-9b-optiq-4bit")
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
        let local = FakeClassifier(id: "local.qwen3.5-9b-optiq-4bit.classifier", displayName: "Downloaded")
        let localMissing = FakeClassifier(id: "local.qwen3.5-9b-optiq-4bit.classifier", displayName: "Downloaded",
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

    @Test func theLargeModelShowsItsDiskAndMemoryNeedsBeforeAnythingDownloads() async {
        let port = FakeClassifierModelPort()
        let model = ClassifierSettingsModel(center: center(), port: port)
        await model.refresh()
        #expect(model.requirementsText == "Needs about 7.1 GB of disk space and about 8 GB of memory while it works, "
            + "so other apps can slow down. It takes over a minute to load, then a few seconds for each email.")
        #expect(model.canDownload && model.unsupportedText == nil)
        #expect(model.statusText == "Not downloaded. Nothing is downloaded until you click.")
        #expect(port.downloads.isEmpty)
        #expect(ClassifierSettingsModel.sizeText(7_120_910_361) == "about 7.1 GB")
        #expect(ClassifierSettingsModel.memoryText(7_973_397_524) == "about 8 GB")
        #expect(ClassifierSettingsModel(center: center(), port: nil).requirementsText == nil)
    }

    @Test func aMacWithTooLittleMemoryIsToldWhyAndCannotStartTheDownload() async {
        let port = FakeClassifierModelPort(unsupportedReason: "Needs a Mac with at least 16 GB of memory.")
        let model = ClassifierSettingsModel(center: center(), port: port)
        await model.refresh()
        #expect(!model.canDownload)
        #expect(model.statusText == "This Mac can't run it. Needs a Mac with at least 16 GB of memory.")
        model.download()
        #expect(port.downloads.isEmpty && model.status == .notDownloaded(partialBytes: 0))
    }

    @Test func anOldModelIsOfferedForDeletionAndOnlyDeletedOnClick() async {
        let old = LeftoverLocalModel(id: "qwen3-1.7b-4bit", name: "Qwen3 1.7B (4-bit)", bytes: 979_503_801)
        let port = FakeClassifierModelPort(leftovers: [old])
        let model = ClassifierSettingsModel(center: center(), port: port)
        await model.refresh()
        #expect(model.leftovers == [old])
        #expect(ClassifierSettingsModel.leftoverText(old)
            == "Mail no longer uses this model. Its files still take about 1 GB on this Mac until you delete them.")
        #expect(port.deletedLeftovers.isEmpty, "showing it deletes nothing")
        await model.deleteLeftover("qwen3.5-9b-optiq-4bit")
        #expect(port.deletedLeftovers.isEmpty, "only a listed leftover can be deleted here")
        await model.deleteLeftover(old.id)
        #expect(port.deletedLeftovers == [old.id] && model.leftovers.isEmpty && model.error == nil)
    }

    @Test func aSavedChoiceOfTheRetiredModelMovesToApplesModelAndIsSavedOnce() async throws {
        var saved = AISettings(classifier: .localModel)
        saved.featurePins[.summarize] = .local("qwen3-1.7b-4bit")
        let legacy = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(saved))
        let store = CountingAISettingsStore(legacy)
        let box = AISettingsBox(store: store)
        #expect(box.current.classifier == .appleModel && box.current.selectedLocalModel == nil)
        #expect(box.current.featurePins.isEmpty)
        #expect(store.saves == 1 && store.load() == box.current)
        _ = AISettingsBox(store: store)
        #expect(store.saves == 1, "nothing is left to move")

        let apple = FakeClassifier(id: "apple.system.classifier", displayName: "Apple")
        let large = FakeClassifier(id: "local.qwen3.5-9b-optiq-4bit.classifier", displayName: "Qwen3.5 9B OptiQ (4-bit)")
        let ai = AICenter.make(registry: ProviderRegistry(classifiers: [large, apple]), settings: box)
        #expect(await AutoLabelCenter.onDeviceClassifier(ai).0?.id == apple.id)

        let fresh = CountingAISettingsStore(AISettings())
        _ = AISettingsBox(store: fresh)
        #expect(fresh.saves == 0)
        var chose = AISettings()
        chose.useClassifier(large.id)
        let kept = CountingAISettingsStore(chose)
        #expect(AISettingsBox(store: kept).current.selectedLocalModel == "qwen3.5-9b-optiq-4bit" && kept.saves == 0)
    }
}

final class CountingAISettingsStore: AISettingsStoring {
    private let state: Mutex<(settings: AISettings, saves: Int)>

    init(_ settings: AISettings) { state = Mutex((settings, 0)) }

    var saves: Int { state.withLock { $0.saves } }
    func load() -> AISettings { state.withLock { $0.settings } }
    func save(_ settings: AISettings) throws { state.withLock { $0 = (settings, $0.saves + 1) } }
}
