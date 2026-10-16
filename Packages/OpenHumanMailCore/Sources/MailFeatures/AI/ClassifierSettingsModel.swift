import Foundation
import Observation
import OpenHumanAI

public enum LocalModelStatus: Sendable, Hashable {
    case notDownloaded(partialBytes: Int64)
    case downloading(bytesDone: Int64, bytesTotal: Int64)
    case verifying
    case ready
    case failed(String)
}

public protocol LocalClassifierModelPort: AnyObject, Sendable {
    var modelName: String { get }
    var sizeBytes: Int64 { get }
    var licence: String { get }
    func directoryPath() async -> String
    func status() async -> LocalModelStatus
    func download(confirmedSizeBytes: Int64) async -> AsyncStream<LocalModelStatus>
    func cancel() async
    func delete() async throws
    func useDirectory(_ path: String?) async throws
}

@MainActor @Observable
public final class ClassifierSettingsModel {
    public let center: AICenter
    public let port: (any LocalClassifierModelPort)?
    public private(set) var status: LocalModelStatus?
    public private(set) var directory: String?
    public private(set) var error: String?
    @ObservationIgnored public var onChange: (@MainActor () async -> Void)?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    public static let title = "Downloaded model"
    public static let footnote = "A model you can download for triage and auto labels instead of Apple's. It runs on this Mac; "
        + "email text never leaves it. Choose it under Model for each feature."
    public static let lowPowerTitle = "Also in Low Power Mode"
    public static let lowPowerDetail = "Off: the downloaded model pauses in Low Power Mode and while the Mac is hot."

    public init(center: AICenter, port: (any LocalClassifierModelPort)?) {
        self.center = center
        self.port = port
    }

    isolated deinit { downloadTask?.cancel() }

    public var preference: ClassifierPreference {
        get { center.settings.classifier }
        set {
            change { $0.classifier = newValue }
            Task { await onChange?() }
        }
    }

    public var allowLowPower: Bool {
        get { center.settings.localClassifierInLowPowerMode }
        set { change { $0.localClassifierInLowPowerMode = newValue } }
    }

    public var downloadTitle: String {
        guard let port else { return "Download classifier model" }
        return "Download classifier model (\(Self.sizeText(port.sizeBytes)))"
    }

    public var isDownloading: Bool {
        switch status {
        case .downloading, .verifying: true
        default: false
        }
    }

    public var canDownload: Bool {
        guard port != nil else { return false }
        switch status {
        case .notDownloaded, .failed: return true
        default: return false
        }
    }

    public var isReady: Bool { status == .ready }

    public var statusText: String {
        guard let port else { return "The downloaded model isn't part of this copy of Mail." }
        switch status {
        case nil: return "Checking…"
        case .notDownloaded(let partial) where partial > 0:
            return "Stopped at \(Self.sizeText(partial)) of \(Self.sizeText(port.sizeBytes)). Download again to resume."
        case .notDownloaded: return "Not downloaded. Nothing is downloaded until you click."
        case .downloading(let done, let total):
            let percent = total > 0 ? Int((Double(done) / Double(total) * 100).rounded(.down)) : 0
            return "Downloading… \(percent)%"
        case .verifying: return "Checking the download…"
        case .ready: return preference == .localModel ? "Downloaded. Used for triage and auto labels."
            : "Downloaded. Not used until you choose it for Triage and auto labels."
        case .failed(let why): return why
        }
    }

    public var progress: Double? {
        if case .downloading(let done, let total) = status, total > 0 { return min(1, Double(done) / Double(total)) }
        return nil
    }

    public func refresh() async {
        guard let port else { return }
        status = await port.status()
        directory = await port.directoryPath()
    }

    public func download() {
        guard let port, canDownload, downloadTask == nil else { return }
        error = nil
        status = .downloading(bytesDone: 0, bytesTotal: port.sizeBytes)
        downloadTask = Task { [weak self] in
            let stream = await port.download(confirmedSizeBytes: port.sizeBytes)
            for await next in stream {
                guard let self else { return }
                self.status = next
            }
            guard let self else { return }
            self.downloadTask = nil
            self.status = await port.status()
            await self.onChange?()
        }
    }

    public func cancel() async {
        await port?.cancel()
        downloadTask?.cancel()
        downloadTask = nil
        await refresh()
    }

    public func delete() async {
        guard let port else { return }
        do {
            try await port.delete()
        } catch {
            self.error = "The model couldn't be deleted."
        }
        await refresh()
        await onChange?()
    }

    public func useDirectory(_ path: String?) async {
        guard let port, !isDownloading else { return }
        do {
            try await port.useDirectory(path)
            change { $0.modelsDirectory = path }
        } catch {
            self.error = "That folder can't be used."
        }
        await refresh()
        await onChange?()
    }

    public static func sizeText(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 0.95 && gigabytes < 1.05 { return "about 1 GB" }
        if gigabytes >= 1 { return String(format: "about %.1f GB", gigabytes) }
        return String(format: "about %.0f MB", Double(bytes) / 1_000_000)
    }

    private func change(_ mutate: (inout AISettings) -> Void) {
        do {
            try center.update(mutate)
            error = nil
        } catch {
            self.error = "The setting couldn't be saved."
        }
    }
}
