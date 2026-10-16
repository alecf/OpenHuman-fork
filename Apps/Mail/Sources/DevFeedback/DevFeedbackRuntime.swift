import AppKit
import Foundation
import MailFeatures
import MailModel
import MailTheme
import MailUIMac
import OpenHumanCore
import OpenHumanStore

@MainActor
enum DevFeedbackRuntime {
    static let checklistWindowID = "dev-checklist"
    static let mainWindowID = "main"

    static var availability: DevFeedbackAvailability { BuildFlavor.hasDevTools ? .devTools : .off }

    static func start(arguments: [String] = ProcessInfo.processInfo.arguments,
                      environment: [String: String] = ProcessInfo.processInfo.environment,
                      app: @escaping @MainActor () -> AppModel? = { MailApp.app }) -> DevFeedbackCenter {
        let availability = Self.availability
        let underTests = environment["XCTestConfigurationFilePath"] != nil
        let paths: DevFeedbackPaths
        let defaults: UserDefaults
        if underTests {
            paths = DevFeedbackPaths(support: FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenHumanMail-DevFeedback-\(UUID().uuidString)", isDirectory: true))
            defaults = UserDefaults(suiteName: "dev.openhuman.mail.tests.devfeedback") ?? .standard
        } else {
            paths = DevFeedbackPaths.resolve(home: BuildFlavor.home(environment),
                                             feedbackDirectory: BuildFlavor.feedbackDirectory(environment))
            defaults = .standard
        }
        let center = DevFeedbackCenter(
            availability: availability, settings: DevFeedbackSettings(defaults: defaults), paths: paths,
            bundledChecklist: Bundle.main.url(forResource: "dev-test-checklist", withExtension: "json"))
        let host = AppDevFeedbackHost(availability: availability, arguments: arguments, environment: environment,
                                      app: app, theme: { AppThemes.themeInfo })
        center.host = host
        Log.setMirror(center.logs.sink)
        return center
    }

    static func attach(_ controller: MainContentViewController, to center: DevFeedbackCenter) {
        guard center.availability.isAvailable else { return }
        center.window = controller.windowModel
        center.adopt(controller.windowModel)
        controller.keyRouter.didRoute = { [weak center] chord, action in
            center?.history.record(action?.rawValue ?? "key:\(keyIdentifier(chord))")
        }
    }

    static func keyIdentifier(_ chord: KeyChord) -> String {
        var parts: [String] = []
        if chord.modifiers.contains(.command) { parts.append("cmd") }
        if chord.modifiers.contains(.option) { parts.append("opt") }
        if chord.modifiers.contains(.control) { parts.append("ctrl") }
        switch chord.key {
        case .character(let c):
            let printable = c.count == 1 && c.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }
            parts.append(printable ? (chord.modifiers.isEmpty ? c : c.lowercased()) : "other")
        case .named(let named): parts.append(String(describing: named))
        }
        return parts.joined(separator: "+")
    }

    static func revealFeedbackFolder(_ center: DevFeedbackCenter) {
        let url = center.paths.feedbackDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
final class AppDevFeedbackHost: DevFeedbackHost {
    private let availability: DevFeedbackAvailability
    private let arguments: [String]
    private let environment: [String: String]
    private let app: @MainActor () -> AppModel?
    private let themeProvider: @MainActor () -> DevFeedbackSnapshot.ThemeInfo?

    init(availability: DevFeedbackAvailability, arguments: [String], environment: [String: String],
         app: @escaping @MainActor () -> AppModel?, theme: @escaping @MainActor () -> DevFeedbackSnapshot.ThemeInfo?) {
        self.availability = availability
        self.arguments = arguments
        self.environment = environment
        self.app = app
        self.themeProvider = theme
    }

    var appInfo: DevFeedbackSnapshot.AppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let mode: String = switch CompositionRoot.dataMode(arguments: arguments, environment: environment) {
        case .fake: "fake"
        case .fixtureStore: "fixtureStore"
        case .fakeGmail: "fakeGmail"
        case .live: "live"
        }
        return DevFeedbackSnapshot.AppInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            gitCommit: (info["OHGitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
            configuration: BuildFlavor.name, dataMode: mode,
            devFeedbackEnabledBy: availability.rawValue,
            os: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    var screenName: String {
        switch app()?.screen {
        case .mail: "mail"
        case .signIn(let model): "signIn/\(DevFeedbackCenter.caseName(model.phase))"
        case .notice: "notice"
        case .launching, nil: "starting"
        }
    }

    var theme: DevFeedbackSnapshot.ThemeInfo? { themeProvider() }

    var extraDenylist: [String] {
        var strings: [String] = []
        if case .signIn(let model) = app()?.screen { strings += [model.loginHint, model.pastedAddress] }
        if let session = app()?.session { strings.append(session.email) }
        return strings
    }

    func keychainDiagnostics() async -> DevFeedbackSnapshot.KeychainInfo? {
        guard let report = app()?.liveAccounts?.keychainDiagnostics() else { return nil }
        return DevFeedbackSnapshot.KeychainInfo(
            entries: report.entries.map { entry in
                var stores: [String] = []
                if entry.local { stores.append("local") }
                if entry.synced { stores.append("synced") }
                if entry.file { stores.append("file") }
                return .init(subject: entry.subject, stores: stores)
            },
            lastStatus: report.lastStatus)
    }

    func accountCounters() async -> [DevFeedbackSnapshot.AccountInfo] {
        guard let app = app() else { return [] }
        if let session = app.session {
            let store = session.store
            return await Task.detached { Self.storeCounters(store) }.value
        }
        if case .mail(let environment) = app.screen, let diagnostics = try? await environment.data.diagnosticsSnapshot() {
            var emails: [String] = []
            if let accounts = try? await Self.first(environment.data.accounts()) { emails = accounts.map(\.email) }
            return diagnostics.accounts.map { entry in
                DevFeedbackSnapshot.AccountInfo(
                    index: entry.index,
                    idHash: entry.index - 1 < emails.count ? DevFeedbackHash.account(emails[entry.index - 1]) : "",
                    health: entry.health, connectivity: entry.connectivity, lastSyncAt: entry.lastSyncAt,
                    consecutiveFailures: entry.consecutiveFailures, threadCount: entry.threadCount,
                    messageCount: entry.messageCount, pendingOperations: entry.pendingOperations,
                    failedOperations: entry.failedOperations)
            }
        }
        return []
    }

    nonisolated static func storeCounters(_ store: MailStore) -> [DevFeedbackSnapshot.AccountInfo] {
        guard let accounts = try? store.accounts() else { return [] }
        let scrubber = DevFeedbackRedactor()
        return accounts.enumerated().map { offset, item in
            let status = try? store.syncStatus(account: item.id)
            let inbox = try? store.label(account: item.id, key: "INBOX")
            let page = try? store.threadPage(view: .system(item.id, .allMail), after: nil, limit: 5_000)
            let log = (try? store.syncLog(account: item.id, limit: 10)) ?? []
            return DevFeedbackSnapshot.AccountInfo(
                index: offset + 1, idHash: DevFeedbackHash.account(item.email),
                health: DevFeedbackCenter.caseName(item.status),
                syncPhase: status.map { DevFeedbackCenter.caseName($0.phase) }, lastSyncAt: status?.lastSuccessAt,
                consecutiveFailures: status?.consecutiveFailures, syncErrorCode: status?.lastError.map(scrubber.scrub),
                historyID: status?.historyID.map { String($0.rawValue) },
                threadCount: page?.items.count, messageCount: page?.items.reduce(0) { $0 + $1.messageCount },
                inboxThreads: inbox?.totalThreads, inboxUnreadThreads: inbox?.unreadThreads,
                pendingOperations: status?.pendingOperations, failedOperations: status?.failedOperations,
                recentSync: log.map { entry in
                    DevFeedbackSnapshot.SyncRun(at: entry.startedAt, kind: entry.kind, outcome: entry.outcome,
                                                requests: entry.requests, added: entry.added, changed: entry.changed,
                                                deleted: entry.deleted, errorCode: entry.errorCode.map(scrubber.scrub))
                })
        }
    }

    private static func first<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T? {
        for try await value in stream { return value }
        return nil
    }

    func captureScreenshot() -> Data? {
        guard let window = mainWindow, let view = window.contentView, view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func showMainWindow() {
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(DevFeedbackRuntime.mainWindowID) == true && $0.isVisible }
            ?? NSApp.mainWindow
    }
}
