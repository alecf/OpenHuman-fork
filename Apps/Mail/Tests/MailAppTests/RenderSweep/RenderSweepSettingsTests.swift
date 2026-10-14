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

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct RenderSweepSettingsTests {
    static let windowSize = NSSize(width: 760, height: 560)
    static let fullHeightSize = NSSize(width: 760, height: 2400)
    static let fullHeightPages: Set<String> = ["ai", "advanced", "platform", "general"]

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
        let center = AICenter.make(registry: ProviderRegistry(providers: [FakeAIProvider(displayName: "Apple on-device model")]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore()))
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
        let notifications = NotificationsSettingsModel(environment: environment)
        let hosting = SettingsHosting(
            appearance: { AnyView(AppearanceSettingsView(store: themes, fontFamilies: ["Inter", "New York"])) },
            notifications: { AnyView(NotificationsSettingsView(model: notifications)) },
            generalExtras: { AnyView(SystemGeneralSettingsView(environment: environment)) },
            aiProviders: {
                AnyView(SettingsSectionStack {
                    AISettingsSection(center: center, environment: environment, listsUnavailableModels: false)
                    if let semantic { SmartSearchIndexSettingsView(services: semantic) }
                })
            })
        let pages = SettingsShellModel(environment: environment).pages
        #expect(pages.count >= 10, "every built-in page and the module pages")
        for page in pages {
            environment.settingsNavigator.open(page.id)
            let shell = SettingsShellView(environment: environment, hosting: hosting)
            let window = Self.window(shell, themes: themes)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(600))
            try Self.shoot(window, screen: "settings-\(page.id)", theme: theme, in: directory)
            if Self.fullHeightPages.contains(page.id) || Self.fullHeightPages.contains(where: { page.id.contains($0) }) {
                environment.settingsNavigator.open(page.id)
                let tall = Self.window(SettingsShellView(environment: environment, hosting: hosting), themes: themes,
                                       size: Self.fullHeightSize)
                defer { tall.orderOut(nil) }
                try await Task.sleep(for: .milliseconds(600))
                try Self.shoot(tall, screen: "settings-\(page.id)-full", theme: theme, in: directory)
            }
        }
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
