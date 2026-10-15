#if os(macOS)
import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanAI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

private let fixedNow = Date(timeIntervalSince1970: 1_791_000_000)

private let pageWidth = SettingsMetrics.windowWidth - SettingsMetrics.sidebarWidth - 1

@MainActor
private func environment() -> AppEnvironment {
    AppEnvironment.fake(corpus: .rich(threadCount: 20, now: fixedNow), options: .init(remoteAck: .immediate),
                        featureFlags: FeatureFlags())
}

@MainActor
private func environmentWithSystem() async throws -> AppEnvironment {
    let env = environment()
    env.installPlatform(SystemPlatform(notifier: FakeSystemNotifier(authorization: .denied), dock: FakeDockBadge(),
                                       loginItem: FakeLoginItem(status: .requiresApproval), urlOpener: FakeURLOpener(),
                                       isAppActive: { false }))
    env.runLaunchTasks()
    try await until("the system modules") { env.system.notifications != nil && env.system.launchAtLogin != nil }
    return env
}

@MainActor
private func until(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + testBackstop
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private final class Stage {
    let window: NSWindow
    let theme: ResolvedTheme

    init<V: View>(_ view: V, width: CGFloat, height: CGFloat, theme: ResolvedTheme) {
        self.theme = theme
        let scheme: ColorScheme = theme.appearance == .dark ? .dark : .light
        let hosting = NSHostingView(rootView: view.environment(\.theme, theme).environment(\.colorScheme, scheme)
            .tint(theme.accentFill.color))
        window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: height), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil) }

    func render(_ name: String) throws -> (pixels: Pixels, scale: CGFloat, size: CGSize) {
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        try writeSnapshot(image, name)
        let pixels = try #require(Pixels(image))
        return (pixels, CGFloat(rep.pixelsWide) / max(rep.size.width, 1), rep.size)
    }

    func strays(in x: ClosedRange<CGFloat>, of shot: (pixels: Pixels, scale: CGFloat, size: CGSize),
                color: ThemeColor) -> [CGPoint] {
        var out: [CGPoint] = []
        var y: CGFloat = 1
        while y < shot.size.height - 1 {
            var px = x.lowerBound
            while px <= x.upperBound {
                if !matches(shot.pixels.at(px, y, scale: shot.scale), color, tolerance: 6) { out.append(CGPoint(x: px, y: y)) }
                px += 4
            }
            y += 2
        }
        return out
    }
}

@MainActor
@Suite(.serialized)
struct SettingsLayoutTests {
    @Test func aSectionWithoutRowsDrawsNothing() {
        let width = CGSize(width: 400, height: 1000)
        func height<V: View>(_ view: V) -> CGFloat {
            NSHostingController(rootView: view.environment(\.theme, .light)).sizeThatFits(in: width).height
        }
        #expect(height(SettingsSection("Empty") { EmptyView() }) == 0)
        #expect(height(SettingsSection("Hosted") { AnyView(EmptyView()) }) == 0, "an app-hosted extra that is off")
        #expect(height(SettingsSection("No rows", footnote: "Never shown.") { ForEach([Int](), id: \.self) { Text("\($0)") } }) == 0)
        let shown = false
        #expect(height(SettingsSection("Off") { if shown { SettingsRow("Hidden") } }) == 0)
        let one = height(SettingsSection("One") { SettingsRow("A row") })
        let two = height(SettingsSection("Two") { SettingsRow("A row"); SettingsRow("Another row") })
        #expect(one > SettingsMetrics.rowMinHeight)
        #expect(two - one >= SettingsMetrics.rowMinHeight, "every row keeps the row height")
        let hosted = height(SettingsSection("Two") { AnyView(Group { SettingsRow("A row"); SettingsRow("Another row") }) })
        #expect(hosted == two, "rows inside an AnyView are still separate rows")
    }

    @Test func hostedSectionsAreAPageSectionApart() {
        let width = CGSize(width: 400, height: 1000)
        func height<V: View>(_ view: V) -> CGFloat {
            NSHostingController(rootView: view.environment(\.theme, .light)).sizeThatFits(in: width).height
        }
        let one = height(SettingsSection("One", footnote: "A note.") { SettingsRow("A row") })
        let two = height(SettingsSectionStack {
            SettingsSection("One", footnote: "A note.") { SettingsRow("A row") }
            SettingsSection("Two", footnote: "A note.") { SettingsRow("A row") }
        })
        #expect(abs(two - (2 * one + ResolvedTheme.light.space7)) < 1, "\(two) vs 2 × \(one) + space.7")
    }

    @Test func aRowWrapsItsTextAndKeepsTheControlInside() {
        let long = String(repeating: "A long setting title that has to wrap ", count: 4)
        let row = SettingsRow(long, detail: "And a detail line that also wraps when the row is narrow.", isOn: .constant(true))
        let size = NSHostingController(rootView: row.environment(\.theme, .light)).sizeThatFits(in: CGSize(width: 300, height: 1000))
        #expect(size.width <= 300)
        #expect(size.height > SettingsMetrics.rowMinHeight, "the title wrapped instead of pushing the switch out")
        let compact = SettingsSection(compact: true) { SettingsRow("Archive") { KeycapView(text: "E") } }
        let compactHeight = NSHostingController(rootView: compact.environment(\.theme, .light))
            .sizeThatFits(in: CGSize(width: 300, height: 1000)).height
        #expect(compactHeight < SettingsMetrics.rowMinHeight, "list-like sections use the 28 pt row")
    }

    @Test(arguments: [("light", ResolvedTheme.light), ("dark", ResolvedTheme.dark)])
    func aSettingsFieldsPlaceholderIsTertiary(_ name: String, _ theme: ResolvedTheme) throws {
        let field = TextField("Search", text: .constant(""), prompt: Text("Search shortcuts").settingsPrompt(theme))
            .settingsTextField()
            .frame(width: 240)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.bgWindow.color)
        let stage = Stage(field, width: 300, height: 80, theme: theme)
        defer { stage.close() }
        let shot = try stage.render("settings-field-placeholder-\(name)")
        func luminance(_ pixel: (Int, Int, Int)) -> Int { (pixel.0 + pixel.1 + pixel.2) / 3 }
        func luminance(_ color: ThemeColor) -> Int { Int(((color.red + color.green + color.blue) / 3 * 255).rounded()) }
        let fill = luminance(theme.bgWindow)
        let tertiary = abs(luminance(theme.textTertiary) - fill)
        var strongest = 0
        var y: CGFloat = 23
        while y <= 41 {
            var x: CGFloat = 23
            while x <= 257 {
                strongest = max(strongest, abs(luminance(shot.pixels.at(x, y, scale: shot.scale)) - fill))
                x += 1 / shot.scale
            }
            y += 1 / shot.scale
        }
        #expect(strongest >= tertiary / 2, "the placeholder is drawn (\(name): \(strongest) of \(tertiary))")
        #expect(strongest <= tertiary + 14, "the placeholder is text.tertiary, not darker (\(name): \(strongest) > \(tertiary))")
    }

    @Test func theSidebarArrowsStopAtTheEnds() {
        let ids = ["general", "accounts", "appearance"]
        #expect(SettingsSidebar.page(after: "general", offset: 1, in: ids) == "accounts")
        #expect(SettingsSidebar.page(after: "accounts", offset: -1, in: ids) == "general")
        #expect(SettingsSidebar.page(after: "general", offset: -1, in: ids) == nil)
        #expect(SettingsSidebar.page(after: "appearance", offset: 1, in: ids) == nil)
        #expect(SettingsSidebar.page(after: "gone", offset: 1, in: ids) == "general", "a page that went away")
    }

    @Test func theSidebarFooterShowsTheVersionAndTheEarlyDevelopmentNotice() {
        #expect(SettingsBuildFooter.lines(BuildLabel(version: "0.1.0", build: "1001", channel: "early-development"))
                == ["Version 0.1.0 (1001)", "Early development build — expect rough edges. Please send feedback."])
        #expect(SettingsBuildFooter.lines(BuildLabel(version: "1.0.0", build: "7", channel: "")) == ["Version 1.0.0 (7)"])
    }

    @Test func signedOutTheSameShellShowsOnlyAppearanceAndAdvanced() {
        let pages = SettingsShellView.standalonePages(SettingsShellModel.standalone().pages)
        #expect(pages.map(\.id) == [SettingsPageID.appearance.rawValue, SettingsPageID.advanced.rawValue])
        let publicPages = SettingsShellView.standalonePages(SettingsShellModel.standalone().pages, showsAdvanced: false)
        #expect(publicPages.map(\.id) == [SettingsPageID.appearance.rawValue])
        #expect(!SettingsHosting().showsDeveloperItems, "what a public build shows, unless the app says otherwise")
        #expect(!SettingsHosting().offersDeveloperSettings, "and no developer options switch")
    }

    @Test(arguments: [("light", ResolvedTheme.light), ("dark", ResolvedTheme.dark)])
    func theShellDrawsTheThemesSidebar(_ name: String, _ theme: ResolvedTheme) throws {
        let stage = Stage(SettingsShellView(environment: environment(), hosting: SettingsHosting(), defaults: .standard),
                          width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight, theme: theme)
        defer { stage.close() }
        let shot = try stage.render("settings-window-\(name)")
        #expect(matches(shot.pixels.at(SettingsMetrics.sidebarWidth / 2, SettingsMetrics.windowHeight - 20, scale: shot.scale),
                        theme.bgSidebar), "below the pages: the theme's sidebar, not a system material")
        let firstRow = 12 + SettingsMetrics.sidebarRowHeight / 2
        #expect(matches(shot.pixels.at(SettingsMetrics.sidebarWidth - 16, firstRow, scale: shot.scale), theme.bgRowSelected),
                "the selected page's plate")
        #expect(matches(shot.pixels.at(SettingsMetrics.windowWidth - 24, SettingsMetrics.windowHeight - 8, scale: shot.scale),
                        theme.bgWindow), "the page's right-hand margin")
    }

    @Test func advancedListsOnlyTheModulesThatNeedARestart() throws {
        let defaults = try #require(UserDefaults(suiteName: "settings-layout-tests-\(UUID().uuidString)"))
        let model = FeaturesSettingsModel(modules: ModuleList.all, registered: [], defaults: defaults)
        let ids = AdvancedSettingsPage.restartRows(model.rows).map(\.id)
        #expect(!ids.isEmpty)
        for live in FeatureModuleID.startsAtOnce { #expect(!ids.contains(live), "\(live) has its live switch elsewhere") }
        #expect(FeatureModuleID.startsAtOnce.contains(.appIntents) && FeatureModuleID.startsAtOnce.contains(.focusFilters))
        #expect(AdvancedSettingsPage.restartRows(model.rows).allSatisfy { !$0.detail.isEmpty && $0.title != $0.id.rawValue },
                "every row has a title and a line under it")
    }

    @Test func aPublicBuildListsOnlyTheUsersOwnFeatureSwitches() throws {
        let defaults = try #require(UserDefaults(suiteName: "settings-layout-tests-\(UUID().uuidString)"))
        let model = FeaturesSettingsModel(modules: ModuleList.all, registered: [], defaults: defaults)
        let developer = AdvancedSettingsPage.featureRows(model.rows, developer: true).map(\.id)
        #expect(developer == AdvancedSettingsPage.restartRows(model.rows).map(\.id))
        let shown = Set(AdvancedSettingsPage.featureRows(model.rows, developer: false).map(\.id))
        #expect(shown.isSubset(of: FeaturesSettingsModel.userFacing))
        #expect(shown.contains(.ai) && !shown.contains(.diagnostics) && !shown.contains(.snooze))
    }

    @Test func missingPlatformFeaturesAreOneLinePerRequirement() {
        let catalog = [PlatformFeature(id: "a", title: "Alpha", detail: ""), PlatformFeature(id: "b", title: "Beta", detail: ""),
                       PlatformFeature(id: "c", title: "Gamma", detail: "", requirement: "A paid account")]
        let rows = PlatformFeaturesModel(availability: PlatformFeatureAvailability(available: ["b"]), catalog: catalog).rows
        let groups = PlatformFeaturesPage.notYet(rows)
        #expect(groups == [PlatformFeaturesPage.MissingGroup(id: "A notarized build", titles: ["Alpha"]),
                           PlatformFeaturesPage.MissingGroup(id: "A paid account", titles: ["Gamma"])])
    }

    @Test(arguments: [("light", ResolvedTheme.light), ("dark", ResolvedTheme.dark)])
    func noPageRunsIntoTheMarginAtTheSmallestWindow(_ name: String, _ theme: ResolvedTheme) async throws {
        let env = try await environmentWithSystem()
        let extras: () -> AnyView = { AnyView(EmptyView()) }
        let privacy = PrivacySettingsModel(environment: env)
        privacy.start()
        let splits = SplitSettingsModel(environment: env)
        splits.start()
        let notifications = NotificationsSettingsModel(environment: env)
        notifications.start()
        try await until("the privacy settings") { privacy.policy != nil }
        try await until("the splits") { !splits.splits.isEmpty }
        try await until("the notification switches") { !notifications.accounts.isEmpty && notifications.showsPermissionWarning }
        let importance = ImportanceSettingsModel(environment: env)
        importance.start()
        try await until("the importance rules") { importance.hasLoaded }
        let rules = try #require(env.importance)
        let account = try #require(importance.account)
        let sender = "someone.with.a.long.name@mail.example-company.com"
        for change in [ImportanceChange(kind: .neverDomain, account: account, value: "example-company.com"),
                       ImportanceChange(kind: .alwaysSender, account: account, value: sender),
                       ImportanceChange(kind: .label, account: account, value: "Clients/Partners and suppliers"),
                       ImportanceChange(kind: .keyword, account: account, value: "quarterly board meeting"),
                       ImportanceChange(kind: .notPitch, account: account, value: sender)] {
            _ = try await rules.apply(change)
        }
        try await until("the importance list") { importance.rules.count == 5 }
        importance.beginAdd(.keyword)
        importance.draft?.value = "invoice"
        let themes = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .system)))
        let pages: [(String, AnyView)] = [
            ("general", AnyView(GeneralSettingsPage(environment: env, extras: { AnyView(SystemGeneralSettingsView(environment: env)) }))),
            ("accounts", AnyView(AccountsSettingsPage(environment: env))),
            ("notifications", AnyView(NotificationsSettingsView(model: notifications))),
            ("splits", AnyView(SplitSettingsPage(model: splits))),
            ("shortcuts", AnyView(ShortcutsSettingsPage(environment: env, printText: { _ in }))),
            ("snippets", AnyView(SnippetSettingsPage(environment: env))),
            ("privacy", AnyView(PrivacySettingsPage(model: privacy))),
            ("ai", AnyView(AISettingsPage(environment: env, providers: nil))),
            ("advanced", AnyView(AdvancedSettingsPage(environment: env, extras: extras))),
            ("platform", AnyView(PlatformFeaturesPage(environment: env))),
            ("calendar", AnyView(CalendarSettingsPage(environment: env))),
            ("appearance", AnyView(AppearanceSettingsView(store: themes, fontFamilies: ["Inter"]))),
            ("importance", AnyView(ImportanceSettingsPage(model: importance))),
        ]
        for (page, view) in pages {
            let stage = Stage(view, width: pageWidth, height: 2400, theme: theme)
            defer { stage.close() }
            let shot = try stage.render("settings-page-\(page)-\(name)")
            let margin = pageWidth - 32
            let strays = stage.strays(in: (margin + 4)...(pageWidth - 6), of: shot, color: theme.bgWindow)
            #expect(strays.isEmpty, "\(page) (\(name)) draws in the right margin at \(strays.prefix(3))")
        }
    }

    @Test func theMarginCheckSeesARowThatRunsOver() throws {
        let page = SettingsPageScaffold(title: "Too wide") {
            SettingsSection { SettingsRow("Wide") { Color.red.frame(width: pageWidth, height: 20) } }
        }
        let stage = Stage(page, width: pageWidth, height: 400, theme: .light)
        defer { stage.close() }
        let shot = try stage.render("settings-page-too-wide")
        #expect(!stage.strays(in: (pageWidth - 28)...(pageWidth - 6), of: shot, color: ResolvedTheme.light.bgWindow).isEmpty)
    }

    @Test(arguments: [("light", ResolvedTheme.light), ("dark", ResolvedTheme.dark)])
    func thePromptsTabStaysInsideThePage(_ name: String, _ theme: ResolvedTheme) async throws {
        let registry = PromptRegistry(provider: PromptLibraryProvider(bundled: .standard),
                                      store: InMemoryPromptOverrideStore(), now: { fixedNow })
        try await registry.save("autolabel.classify", body: "Pick the one category that fits this conversation best.",
                                note: "plainer wording")
        let model = PromptsSettingsModel(registry: registry)
        await model.load()
        func check(_ shot: String) throws {
            let page = SettingsPageScaffold(title: "AI") {
                AISettingsTabs(prompts: model, initialTab: .prompts) { EmptyView() }
            }
            let stage = Stage(page, width: pageWidth, height: 2400, theme: theme)
            defer { stage.close() }
            let rendered = try stage.render("settings-ai-prompts-\(shot)-\(name)")
            let margin = pageWidth - 32
            let strays = stage.strays(in: (margin + 4)...(pageWidth - 6), of: rendered, color: theme.bgWindow)
            #expect(strays.isEmpty, "prompts \(shot) (\(name)) draws in the right margin at \(strays.prefix(3))")
        }
        try check("list")
        await model.select("autolabel.classify")
        model.draft = "Pick the category."
        #expect(model.check.warnings == [.noJSONForm])
        for tab in PromptsSettingsModel.EditorTab.allCases {
            model.tab = tab
            try check("editor-\(tab.rawValue)")
        }
    }

    @Test func theSplitListShowsEveryRowWithoutScrollingInsideThePage() async throws {
        let splits = SplitSettingsModel(environment: environment())
        splits.start()
        try await until("the splits") { !splits.splits.isEmpty }
        let stage = Stage(SplitSettingsPage(model: splits), width: pageWidth, height: 1200, theme: .light)
        defer { stage.close() }
        _ = try stage.render("settings-splits-list")
        let root = try #require(stage.window.contentView)
        let table = try #require(Self.tables(in: root).first, "the split list is a table")
        let scroll = try #require(table.enclosingScrollView)
        let shown = scroll.contentView.bounds.height
        let rows = table.numberOfRows
        #expect(rows == splits.splits.count + 1, "every split and Other")
        let content = table.rect(ofRow: rows - 1).maxY
        #expect(content <= shown + 0.5, "the last row is inside the list (\(content) of \(shown))")
        #expect(shown - content < SplitSettingsPage.listRowHeight, "no empty row's worth of space under the list")
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }
}
#endif
