import Foundation
import MailModel
import Observation

public struct SendFeedbackDependencies {
    public var runner: (any TailscaleRunning)?
    public var now: @Sendable () -> Date
    public var appInfo: @Sendable () -> DiagnosticsAppInfo
    public var accountCount: @MainActor () async -> Int
    public var diagnostics: @MainActor () async -> Data?
    public var screenshot: @MainActor () -> Data?
    public var thread: @MainActor () -> FeedbackThreadHeader?
    public var contributors: [any FeedbackContributor]
    public var savedDevice: @MainActor () -> String
    public var saveDevice: @MainActor (String) -> Void
    public var chooseSaveLocation: @MainActor (_ suggestedName: String) -> URL?
    public var share: @MainActor (URL) -> Void
    public var temporaryRoot: URL
    public var statusTimeout: Duration
    public var sendTimeout: Duration

    public init(runner: (any TailscaleRunning)?, now: @escaping @Sendable () -> Date = { Date() },
                appInfo: @escaping @Sendable () -> DiagnosticsAppInfo,
                accountCount: @escaping @MainActor () async -> Int = { 0 },
                diagnostics: @escaping @MainActor () async -> Data? = { nil },
                screenshot: @escaping @MainActor () -> Data? = { nil },
                thread: @escaping @MainActor () -> FeedbackThreadHeader? = { nil },
                contributors: [any FeedbackContributor] = [],
                savedDevice: @escaping @MainActor () -> String = { "" },
                saveDevice: @escaping @MainActor (String) -> Void = { _ in },
                chooseSaveLocation: @escaping @MainActor (String) -> URL? = { _ in nil },
                share: @escaping @MainActor (URL) -> Void = { _ in },
                temporaryRoot: URL = FileManager.default.temporaryDirectory,
                statusTimeout: Duration = .seconds(10), sendTimeout: Duration = .seconds(120)) {
        self.runner = runner
        self.now = now
        self.appInfo = appInfo
        self.accountCount = accountCount
        self.diagnostics = diagnostics
        self.screenshot = screenshot
        self.thread = thread
        self.contributors = contributors
        self.savedDevice = savedDevice
        self.saveDevice = saveDevice
        self.chooseSaveLocation = chooseSaveLocation
        self.share = share
        self.temporaryRoot = temporaryRoot
        self.statusTimeout = statusTimeout
        self.sendTimeout = sendTimeout
    }
}

@MainActor @Observable
public final class SendFeedbackModel {
    public enum Devices: Equatable {
        case noCLI
        case loading
        case ready
        case unavailable(String)
    }

    public enum Phase: Equatable {
        case editing, sending
        case sent(device: String)
        case saved(fileName: String)
        case failed(String)
    }

    public var note = ""
    public var includeDiagnostics = true
    public var includeScreenshot = false
    public var includeThread = false
    public var extraSelection: [String: Bool]
    public var selectedDevice: String? {
        didSet { if let selectedDevice, selectedDevice != oldValue, devices.contains(where: { $0.target == selectedDevice }) {
            dependencies.saveDevice(selectedDevice)
        } }
    }

    public private(set) var devices: [TailscaleDevice] = []
    public private(set) var deviceState: Devices
    public private(set) var phase: Phase = .editing
    public let screenshotPNG: Data?
    public let threadHeader: FeedbackThreadHeader?
    public let contributors: [any FeedbackContributor]

    @ObservationIgnored private let dependencies: SendFeedbackDependencies
    @ObservationIgnored private var shareFolders: [URL] = []

    public init(_ dependencies: SendFeedbackDependencies) {
        self.dependencies = dependencies
        self.deviceState = dependencies.runner == nil ? .noCLI : .loading
        self.screenshotPNG = dependencies.screenshot()
        self.threadHeader = dependencies.thread()
        self.contributors = dependencies.contributors
        self.extraSelection = Dictionary(uniqueKeysWithValues: dependencies.contributors.map { ($0.id, $0.isOnByDefault) })
    }

    public var canIncludeScreenshot: Bool { screenshotPNG != nil }
    public var canIncludeThread: Bool { threadHeader != nil }
    public var isBusy: Bool { phase == .sending }
    public var showsFallbacks: Bool {
        switch (deviceState, phase) {
        case (.noCLI, _), (.unavailable, _), (_, .failed): true
        default: false
        }
    }
    public var canSend: Bool {
        guard deviceState == .ready, let selectedDevice, devices.contains(where: { $0.target == selectedDevice }) else { return false }
        switch phase {
        case .editing, .failed: return true
        default: return false
        }
    }

    public func load() async {
        guard let runner = dependencies.runner else { deviceState = .noCLI; return }
        deviceState = .loading
        do {
            let result = try await runner.run(arguments: TaildropArguments.statusArguments, timeout: dependencies.statusTimeout)
            guard result.exitCode == 0 else {
                deviceState = .unavailable("Tailscale did not answer. Open the Tailscale app and sign in, then reopen this sheet.")
                return
            }
            devices = try TailscaleStatusParser.devices(from: result.output)
        } catch TailscaleStatusParser.Failure.notRunning {
            deviceState = .unavailable("Tailscale is not running. Turn it on, then reopen this sheet.")
            return
        } catch is TailscaleRunError {
            deviceState = .unavailable("Tailscale did not answer in time. Open the Tailscale app, then reopen this sheet.")
            return
        } catch {
            deviceState = .unavailable("Couldn't read the list of devices from Tailscale.")
            return
        }
        guard !devices.isEmpty else {
            deviceState = .unavailable("None of your other devices is online on your Tailscale network (phones are not listed).")
            return
        }
        deviceState = .ready
        let saved = dependencies.savedDevice()
        if devices.contains(where: { $0.target == saved }) {
            selectedDevice = saved
        } else if devices.count == 1 {
            selectedDevice = devices[0].target
        }
    }

    public var selectedDeviceName: String? {
        selectedDevice.flatMap { id in devices.first { $0.target == id }?.displayName }
    }

    private func makeBundle() async throws -> FeedbackBundle {
        let ticked = contributors.filter { extraSelection[$0.id] == true }
        var diagnostics: [String: Data]?
        if includeDiagnostics {
            if let zip = await dependencies.diagnostics(), let entries = ZipArchive.read(zip) { diagnostics = entries }
        }
        var extras: [String: [FeedbackAttachment]] = [:]
        for contributor in ticked { extras[contributor.id] = await contributor.attachments() }
        let input = FeedbackInput(
            note: note, app: dependencies.appInfo(), accountCount: await dependencies.accountCount(), diagnostics: diagnostics,
            screenshotPNG: includeScreenshot ? screenshotPNG : nil, thread: includeThread ? threadHeader : nil, extras: extras,
            now: dependencies.now())
        return try FeedbackBundler.build(input)
    }

    private func writeTemporary(_ bundle: FeedbackBundle) throws -> (folder: URL, file: URL) {
        let folder = dependencies.temporaryRoot.appendingPathComponent("OpenHuman-feedback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(bundle.fileName)
        try bundle.data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return (folder, file)
    }

    public func send() async {
        guard canSend, let runner = dependencies.runner, let device = selectedDevice else { return }
        phase = .sending
        let name = selectedDeviceName ?? device
        var folder: URL?
        defer { if let folder { try? FileManager.default.removeItem(at: folder) } }
        do {
            let built = try await makeBundle()
            let written = try writeTemporary(built)
            folder = written.folder
            let arguments = try TaildropArguments.copy(file: written.file, to: device, among: devices)
            let result = try await runner.run(arguments: arguments, timeout: dependencies.sendTimeout)
            if result.exitCode == 0 {
                dependencies.saveDevice(device)
                phase = .sent(device: name)
            } else {
                phase = .failed(Self.message(forFailure: result.errorText, device: name))
            }
        } catch TailscaleRunError.timedOut {
            phase = .failed("Sending to \(name) took too long, so it was stopped. Is that device awake and online?")
        } catch TailscaleRunError.launchFailed {
            phase = .failed("Couldn't start Tailscale.")
        } catch let error as TaildropArguments.Invalid {
            phase = .failed(error == .badPath ? "Couldn't prepare the file." : "That device isn't on your Tailscale list any more.")
        } catch {
            phase = .failed("Couldn't prepare the feedback file.")
        }
    }

    static func message(forFailure stderr: String, device: String) -> String {
        let text = stderr.lowercased()
        if text.contains("not logged in") || text.contains("logged out") || text.contains("needslogin") {
            return "Tailscale is signed out. Sign in from the Tailscale app, then try again."
        }
        if text.contains("not running") || text.contains("stopped") || text.contains("failed to connect to local") {
            return "Tailscale isn't running. Turn it on, then try again."
        }
        if text.contains("no such host") || text.contains("unknown") || text.contains("not found") || text.contains("no matching") {
            return "Tailscale can't find \(device). Check that it is online and shares files with this Mac."
        }
        if text.contains("denied") || text.contains("forbidden") || text.contains("not allowed") {
            return "\(device) did not accept the file. Check that Taildrop is allowed for it."
        }
        return "Tailscale couldn't send the file to \(device)."
    }

    public func saveInstead() async {
        guard !isBusy else { return }
        do {
            let built = try await makeBundle()
            guard let url = dependencies.chooseSaveLocation(built.fileName) else { return }
            try built.data.write(to: url, options: .atomic)
            phase = .saved(fileName: url.lastPathComponent)
        } catch {
            phase = .failed("Couldn't save the file.")
        }
    }

    public func share() async {
        guard !isBusy else { return }
        do {
            let written = try writeTemporary(try await makeBundle())
            shareFolders.append(written.folder)
            dependencies.share(written.file)
        } catch {
            phase = .failed("Couldn't prepare the file to share.")
        }
    }

    public func close() {
        let folders = shareFolders
        shareFolders = []
        guard !folders.isEmpty else { return }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(600))
            for folder in folders { try? FileManager.default.removeItem(at: folder) }
        }
    }

    public func removeSharedCopyNow() {
        for folder in shareFolders { try? FileManager.default.removeItem(at: folder) }
        shareFolders = []
    }
}

@MainActor @Observable
public final class SendFeedbackCenter {
    public var model: SendFeedbackModel?
    public var isPresented: Bool {
        get { model != nil }
        set { if !newValue { model?.close(); model = nil } }
    }

    @ObservationIgnored public var makeModel: (@MainActor () -> SendFeedbackModel)?
    @ObservationIgnored public var showWindow: (@MainActor () -> Void)?
    @ObservationIgnored public weak var window: MailWindowModel?
    @ObservationIgnored public var isOffered: @MainActor () -> Bool = { false }

    public static let menuTitle = "Send Feedback to Another Device…"
    public static let sheetTitle = "Send feedback to another device"
    public static let settingsTitle = "Send feedback to another device"
    public static let settingsDetail = "Sends your note and, if you tick them, scrubbed diagnostics and a screenshot to "
        + "one of your own devices over Tailscale. Nothing is sent until you press Send."

    public init() {}

    public var canBegin: Bool { makeModel != nil && isOffered() }

    public func begin() {
        guard model == nil, canBegin, let makeModel else { return }
        showWindow?()
        let made = makeModel()
        model = made
        Task { await made.load() }
    }

    public func threadHeader() -> FeedbackThreadHeader? {
        guard let window, window.mode == .reader, let reader = window.reader else { return nil }
        let name = reader.messages.last?.summary.from?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sender = name.isEmpty ? "(no name)" : DevFeedbackRedactor().scrub(name)
        return FeedbackThreadHeader(subject: reader.subject, senderName: sender)
    }
}
