import AppKit
import Foundation
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanSemanticIndex
import OpenHumanStore
import SwiftUI
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct RenderSweepSettingsTests {
    static let windowSize = NSSize(width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight)
    static let fullHeightSize = NSSize(width: SettingsMetrics.windowWidth, height: 2400)
    static let fullHeightPages: Set<String> = ["ai", "advanced", "platform", "general", "sidebar"]

    @Test func refusesAnOutputFolderInsideAGitWorkTree() throws {
        let here = (#filePath as NSString).deletingLastPathComponent
        let tree = try #require(RenderSweepOutput.gitWorkTree(containing: here), "this source file is in a checkout")
        let inside = (here as NSString).appendingPathComponent("renders-\(UUID().uuidString)")
        #expect(throws: RenderSweepOutput.Refusal.self) { try RenderSweepOutput.checkedDirectory(inside) }
        #expect(!FileManager.default.fileExists(atPath: inside), "nothing was created inside the checkout")
        #expect(throws: RenderSweepOutput.Refusal.self) { try RenderSweepOutput.checkedDirectory(tree) }
        #expect(throws: RenderSweepOutput.Refusal.self) { try RenderSweepOutput.checkedDirectory(nil) }
        _ = try RenderSweepOutput.directory()
    }

    @Test(arguments: RenderSweepTheme.builtIns)
    func everySettingsPage(_ theme: RenderSweepTheme) async throws {
        let directory = try RenderSweepOutput.directory()
        let center = Self.aiCenter()
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 20, now: Date()), options: .init(remoteAck: .immediate),
                                              featureFlags: FeatureFlags(), ai: center, calendar: FakeCalendar.sample())
        environment.installPlatform(SystemPlatform(notifier: FakeSystemNotifier(authorization: .denied), dock: FakeDockBadge(),
                                                   loginItem: FakeLoginItem(status: .requiresApproval),
                                                   urlOpener: FakeURLOpener(), isAppActive: { false }))
        environment.runLaunchTasks()
        await eventually("the system modules") {
            environment.system.notifications != nil && environment.system.launchAtLogin != nil
        }
        let themes = theme.makeStore()
        let semantic = SemanticServices(store: try MailStore.openInMemoryForTesting(), storage: .inMemory, ai: center,
                                        makeProvider: { nil })
        #expect(semantic != nil, "the smart search rows need a store with semantic reads")
        PromptServices.install(persistent: false, directory: nil)
        let notifications = NotificationsSettingsModel(environment: environment)
        func hosting(_ tab: AISettingsTab = .overview) -> SettingsHosting {
            SettingsHosting(
                appearance: { AnyView(AppearanceSettingsView(store: themes, fontFamilies: ["Inter", "New York"])) },
                notifications: { AnyView(NotificationsSettingsView(model: notifications)) },
                generalExtras: { AnyView(SystemGeneralSettingsView(environment: environment)) },
                aiProviders: {
                    AISettingsPageContent.view(center: center, environment: environment, showsDeveloperItems: false,
                                               classifier: SweepClassifierPort(), semantic: semantic, initialTab: tab)
                })
        }
        let pages = SettingsShellModel(environment: environment).pages
        #expect(pages.count >= 10, "every built-in page and the module pages")
        for page in pages {
            environment.settingsNavigator.open(page.id)
            let shell = SettingsShellView(environment: environment, hosting: hosting())
            let window = Self.window(shell, themes: themes)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(600))
            try Self.shoot(window, screen: "settings-\(page.id)", theme: theme, in: directory)
            if Self.fullHeightPages.contains(page.id) || Self.fullHeightPages.contains(where: { page.id.contains($0) }) {
                environment.settingsNavigator.open(page.id)
                let tall = Self.window(SettingsShellView(environment: environment, hosting: hosting()), themes: themes,
                                       size: Self.fullHeightSize)
                defer { tall.orderOut(nil) }
                try await Task.sleep(for: .milliseconds(600))
                try Self.shoot(tall, screen: "settings-\(page.id)-full", theme: theme, in: directory)
            }
        }
        for tab in [AISettingsTab.prompts, .activity] {
            environment.settingsNavigator.open("ai")
            let window = Self.window(SettingsShellView(environment: environment, hosting: hosting(tab)), themes: themes,
                                     size: Self.fullHeightSize)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(600)) // flake-ok: opt-in render sweep; layout settles before the shot
            try Self.shoot(window, screen: "settings-ai-\(tab.rawValue)-full", theme: theme, in: directory)
        }
    }

    static func aiCenter() -> AICenter {
        let claude = FakeAIProvider(id: .agentClaude, displayName: "Claude Code",
                                    capabilities: .fake(dataLocation: .thirdParty(vendor: "Anthropic")))
        let apple = FakeClassifier(id: .appleSystemClassifier, displayName: "Apple on-device model")
        let downloaded = FakeClassifier(id: "local.qwen3.5-9b-optiq-4bit.classifier", displayName: "Qwen3.5 9B OptiQ (4-bit)",
                                        availability: .unavailable(reason: .modelNotDownloaded(sizeBytes: 7_120_910_361)))
        let registry = ProviderRegistry(providers: [FakeAIProvider(id: .appleSystem, displayName: "Apple on-device model")],
                                        classifiers: [apple, downloaded])
        return AICenter.make(registry: registry, settings: AISettingsBox(store: InMemoryAISettingsStore()),
                             traces: InMemoryAITraceStore(SweepSettingsTraces.all), makeProvider: { id in
                                 id == .agentClaude ? claude : nil
                             })
    }

    static func window<V: View>(_ view: V, themes: ThemeStore, size windowSize: NSSize = windowSize) -> NSWindow {
        let content = view
            .frame(width: windowSize.width, height: windowSize.height)
            .background(themes.resolved.bgWindow.color)
            .themed(by: themes)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: windowSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: themes.resolved.appearance == .dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: windowSize)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    static func shoot(_ window: NSWindow, screen: String, theme: RenderSweepTheme, in directory: URL) throws {
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let file = "\(screen)--\(theme.slug).png"
        try png.write(to: directory.appendingPathComponent(file))
        try RenderSweepIndex.record(screen: screen, theme: theme.name, file: file, in: directory)
    }
}

final class SweepClassifierPort: LocalClassifierModelPort, Sendable {
    let modelName = "Qwen3.5 9B OptiQ (4-bit)"
    let classifierID: AIProviderID = "local.qwen3.5-9b-optiq-4bit.classifier"
    let sizeBytes: Int64 = 7_120_910_361
    let memoryBytes: Int64 = 7_973_397_524
    let licence = "Apache-2.0"
    let unsupportedReason: String? = nil

    func directoryPath() async -> String { "~/Library/Application Support/OpenHuman/Models" }
    func status() async -> LocalModelStatus { .notDownloaded(partialBytes: 0) }
    func download(confirmedSizeBytes: Int64) async -> AsyncStream<LocalModelStatus> { AsyncStream { $0.finish() } }
    func cancel() async {}
    func delete() async throws {}
    func useDirectory(_ path: String?) async throws {}
    func leftoverModels() async -> [LeftoverLocalModel] {
        [LeftoverLocalModel(id: "qwen3-1.7b-4bit", name: "Qwen3 1.7B (4-bit)", bytes: 979_503_801)]
    }
    func deleteLeftover(id: String) async throws {}
}

struct RenderSweepTheme: Sendable, CustomTestStringConvertible {
    let name: String
    let slug: String
    let preferences: ThemePreferences

    var testDescription: String { name }

    @MainActor func makeStore() -> ThemeStore {
        ThemeStore(preferencesStore: MemoryThemePreferencesStore(preferences),
                   systemAppearance: preferences.mode == .dark ? .dark : .light)
    }

    static let builtIns: [RenderSweepTheme] = [
        RenderSweepTheme(name: "Light", slug: "light", preferences: ThemePreferences(mode: .light, lightThemeID: BuiltinThemeID.light)),
        RenderSweepTheme(name: "Dark", slug: "dark", preferences: ThemePreferences(mode: .dark, darkThemeID: BuiltinThemeID.dark)),
        RenderSweepTheme(name: "Paper", slug: "paper", preferences: ThemePreferences(mode: .light, lightThemeID: BuiltinThemeID.paper)),
        RenderSweepTheme(name: "Midnight", slug: "midnight",
                         preferences: ThemePreferences(mode: .dark, darkThemeID: BuiltinThemeID.midnight)),
        RenderSweepTheme(name: "System Light", slug: "system-light",
                         preferences: ThemePreferences(mode: .light, lightThemeID: BuiltinThemeID.systemLight)),
        RenderSweepTheme(name: "System Dark", slug: "system-dark",
                         preferences: ThemePreferences(mode: .dark, darkThemeID: BuiltinThemeID.systemDark)),
    ]
}

enum RenderSweepOutput {
    enum Refusal: Error, CustomStringConvertible {
        case notSet
        case insideGitWorkTree(directory: String, workTree: String)

        var description: String {
            switch self {
            case .notSet: "OH_SNAPSHOT_DIR is not set"
            case .insideGitWorkTree(let directory, let workTree):
                "\(directory) is inside the git work tree \(workTree); pick a folder outside every checkout"
            }
        }
    }

    static func gitWorkTree(containing path: String) -> String? {
        var current = ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        while true {
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current { return nil }
            current = parent
        }
    }

    static func checkedDirectory(_ path: String?) throws -> URL {
        guard let raw = path, !raw.isEmpty else { throw Refusal.notSet }
        let expanded = (raw as NSString).expandingTildeInPath
        let absolute = (expanded as NSString).isAbsolutePath
            ? expanded : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        if let tree = gitWorkTree(containing: absolute) { throw Refusal.insideGitWorkTree(directory: absolute, workTree: tree) }
        try FileManager.default.createDirectory(atPath: absolute, withIntermediateDirectories: true)
        if let tree = gitWorkTree(containing: absolute) { throw Refusal.insideGitWorkTree(directory: absolute, workTree: tree) }
        return URL(fileURLWithPath: absolute, isDirectory: true)
    }

    static func directory() throws -> URL {
        try checkedDirectory(ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"])
    }
}

enum RenderSweepIndex {
    struct Entry: Codable, Equatable {
        let screen: String
        let theme: String
        let file: String
    }

    static func record(screen: String, theme: String, file: String, in directory: URL) throws {
        let url = directory.appendingPathComponent("index.json")
        var entries: [Entry] = []
        if let data = try? Data(contentsOf: url) { entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? [] }
        entries.removeAll { $0.file == file }
        entries.append(Entry(screen: screen, theme: theme, file: file))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}

enum SweepSettingsTraces {
    static let start = Date(timeIntervalSince1970: 1_791_799_680)

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)) ?? UUID() }

    static let all: [AITraceRecord] = [
        AITraceRecord(id: id(1), createdAt: start.addingTimeInterval(-240), feature: .rewrite, task: .rewrite, trigger: .user,
                      promptID: PromptID("rewrite.instruct", version: 2), providerID: .appleSystem,
                      providerName: "Apple on-device model", dataLocation: .onDevice,
                      systemText: "Rewrite the user's draft as they ask.", inputText: "Draft\nthursday works",
                      outputText: "Thursday works for me.", finalText: "Thursday works for me.",
                      usage: AIUsage(inputTokens: 210, outputTokens: 9), latencyMilliseconds: 980, cache: .miss,
                      outcome: .completed, rating: 1),
        AITraceRecord(id: id(2), createdAt: start.addingTimeInterval(-600), feature: .askInbox, task: .askInbox,
                      trigger: .user, promptID: PromptID("ask.inbox", version: 1), providerID: .agentClaude,
                      providerName: "Claude Code", dataLocation: .thirdParty(vendor: "Anthropic"),
                      outputText: "The invoice from the print shop is due Friday.",
                      finalText: "The invoice from the print shop is due Friday.", countedInputTokens: 1_840,
                      latencyMilliseconds: 6_200, cache: .miss, outcome: .completed),
        AITraceRecord(id: id(3), createdAt: start.addingTimeInterval(-900), feature: .summarize, task: .summarize,
                      trigger: .automatic, promptID: PromptID("summarize.line", version: 1), providerID: .appleSystem,
                      providerName: "Apple on-device model", dataLocation: .onDevice, countedInputTokens: 2_210,
                      latencyMilliseconds: 20_000, cache: .miss, outcome: .failed, errorKind: "timeout",
                      errorText: "The model took too long"),
    ]
}
