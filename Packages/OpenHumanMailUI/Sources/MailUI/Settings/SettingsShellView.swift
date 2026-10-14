import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct SettingsHosting {
    public var appearance: () -> AnyView
    public var notifications: () -> AnyView
    public var generalExtras: () -> AnyView
    public var advancedExtras: () -> AnyView
    public var aiProviders: (() -> AnyView)?
    public var modulePage: (String) -> AnyView?
    public var printText: (String) -> Void
    public var showsDeveloperItems: Bool
    public var offersDeveloperSettings: Bool
    public var build: BuildLabel?

    public init(appearance: @escaping () -> AnyView = { AnyView(EmptyView()) },
                notifications: @escaping () -> AnyView = { AnyView(EmptyView()) },
                generalExtras: @escaping () -> AnyView = { AnyView(EmptyView()) },
                advancedExtras: @escaping () -> AnyView = { AnyView(EmptyView()) },
                aiProviders: (() -> AnyView)? = nil, modulePage: @escaping (String) -> AnyView? = { _ in nil },
                printText: @escaping (String) -> Void = { _ in }, showsDeveloperItems: Bool = false,
                offersDeveloperSettings: Bool = false, build: BuildLabel? = nil) {
        self.appearance = appearance
        self.notifications = notifications
        self.generalExtras = generalExtras
        self.advancedExtras = advancedExtras
        self.aiProviders = aiProviders
        self.modulePage = modulePage
        self.printText = printText
        self.showsDeveloperItems = showsDeveloperItems
        self.offersDeveloperSettings = offersDeveloperSettings
        self.build = build
    }
}

public struct SettingsShellView: View {
    @State private var shell: SettingsShellModel
    let environment: AppEnvironment?
    let hosting: SettingsHosting
    @Environment(\.theme) private var theme

    public init(environment: AppEnvironment, hosting: SettingsHosting, defaults: UserDefaults = .standard) {
        self.environment = environment
        self.hosting = hosting
        _shell = State(initialValue: SettingsShellModel(environment: environment, defaults: defaults))
    }

    public init(standaloneHosting hosting: SettingsHosting) {
        environment = nil
        self.hosting = hosting
        let model = SettingsShellModel.standalone()
        model.selected = SettingsPageID.appearance.rawValue
        _shell = State(initialValue: model)
    }

    private var pages: [SettingsPageEntry] {
        environment == nil
            ? Self.standalonePages(shell.pages, showsAdvanced: hosting.showsDeveloperItems || hosting.offersDeveloperSettings)
            : shell.pages
    }

    static func standalonePages(_ pages: [SettingsPageEntry], showsAdvanced: Bool = true) -> [SettingsPageEntry] {
        pages.filter { $0.builtIn == .appearance || (showsAdvanced && $0.builtIn == .advanced) }
    }

    public var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(pages: pages, selection: $shell.selected, build: hosting.build)
            Rectangle().fill(theme.borderHairline.color).frame(width: theme.borderWidthHairline)
            VStack(spacing: 0) {
                if environment != nil, let banner = shell.availability.banner {
                    bannerLine(banner)
                }
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(theme.bgWindow.color)
        .navigationTitle(shell.selectedEntry?.title ?? "Settings")
        .onAppear { followRequest() }
        .onChange(of: environment?.settingsNavigator.requestedPage) { followRequest() }
    }

    private func followRequest() {
        guard let navigator = environment?.settingsNavigator else { return }
        shell.takeRequest(from: navigator)
    }

    private func bannerLine(_ banner: String) -> some View {
        Label(banner, systemImage: "lock.fill")
            .themeFont(theme.typeMeta)
            .foregroundStyle(theme.textPrimary.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, theme.space4)
            .padding(.horizontal, theme.space8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.bgWarningSubtle.color)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.safeModeBanner")
    }

    @ViewBuilder
    private var page: some View {
        if let entry = shell.selectedEntry {
            if let builtIn = entry.builtIn {
                builtInPage(builtIn)
            } else if let hosted = hosting.modulePage(entry.id) {
                hosted
            } else if entry.id == ImportanceSettingsModel.pageID, let environment {
                ImportanceSettingsPage(environment: environment)
            } else if entry.id == BlockedSettingsModel.pageID, let environment {
                BlockedSettingsPage(environment: environment)
            } else {
                SettingsPageScaffold(title: entry.title) {
                    SettingsFootnote("Nothing to set on this page yet.")
                }
            }
        }
    }

    @ViewBuilder
    private func builtInPage(_ page: SettingsPageID) -> some View {
        if let environment {
            builtInPage(page, environment: environment)
        } else if page == .appearance {
            hosting.appearance()
        } else {
            SettingsPageScaffold(title: page.title) {
                hosting.advancedExtras()
            }
        }
    }

    @ViewBuilder
    private func builtInPage(_ page: SettingsPageID, environment: AppEnvironment) -> some View {
        switch page {
        case .general: GeneralSettingsPage(environment: environment, extras: hosting.generalExtras)
        case .accounts: AccountsSettingsPage(environment: environment)
        case .appearance: hosting.appearance()
        case .splitInbox: SplitSettingsPage(environment: environment)
        case .shortcuts: ShortcutsSettingsPage(environment: environment, printText: hosting.printText)
        case .snippets: SnippetSettingsPage(environment: environment)
        case .ai: AISettingsPage(environment: environment, providers: hosting.aiProviders)
        case .notifications: hosting.notifications()
        case .calendar: CalendarSettingsPage(environment: environment)
        case .privacy: PrivacySettingsPage(environment: environment)
        case .advanced: AdvancedSettingsPage(environment: environment, extras: hosting.advancedExtras,
                                             showsDeveloperItems: hosting.showsDeveloperItems)
        case .platform: PlatformFeaturesPage(environment: environment, showsDeveloperItems: hosting.showsDeveloperItems)
        }
    }
}

struct SettingsSidebar: View {
    let pages: [SettingsPageEntry]
    @Binding var selection: String
    var build: BuildLabel?
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: theme.space1) {
                    ForEach(pages) { entry in
                        SettingsSidebarRow(entry: entry, isSelected: entry.id == selection, showsCursor: focused) {
                            selection = entry.id
                        }
                    }
                }
                .padding(theme.space3)
            }
            if let build {
                SettingsBuildFooter(build: build)
            }
        }
        .frame(width: SettingsMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(theme.bgSidebar.color)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings pages")
    }

    private func move(by offset: Int) -> KeyPress.Result {
        if let next = Self.page(after: selection, offset: offset, in: pages.map(\.id)) { selection = next }
        return .handled
    }

    static func page(after current: String, offset: Int, in ids: [String]) -> String? {
        guard let index = ids.firstIndex(of: current) else { return ids.first }
        let target = min(max(index + offset, 0), ids.count - 1)
        return target == index ? nil : ids[target]
    }
}

struct SettingsBuildFooter: View {
    let build: BuildLabel
    @Environment(\.theme) private var theme

    static func lines(_ build: BuildLabel) -> [String] {
        [build.versionLine] + (build.notice.map { [$0] } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space1) {
            ForEach(Self.lines(build), id: \.self) { Text($0) }
        }
        .themeFont(theme.typeMeta)
        .foregroundStyle(theme.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.space3 * 2)
        .padding(.vertical, theme.space4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.buildNotice")
    }
}

private struct SettingsSidebarRow: View {
    let entry: SettingsPageEntry
    let isSelected: Bool
    let showsCursor: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space3) {
                Image(systemName: entry.symbol)
                    .font(.system(size: SettingsMetrics.sidebarIconSize))
                    .foregroundStyle((isSelected ? theme.accentText : theme.textSecondary).color)
                    .frame(width: theme.space6)
                    .accessibilityHidden(true)
                Text(entry.title)
                    .themeFont(isSelected ? theme.typeBodyStrong : theme.typeBody)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space3)
            .frame(height: SettingsMetrics.sidebarRowHeight)
            .background(plate)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.page.\(entry.id)")
    }

    private var plate: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(isSelected ? theme.bgRowSelected.color : (hovering ? theme.bgRowHover.color : .clear))
            if isSelected && showsCursor {
                Rectangle().fill(theme.accentRing.color).frame(width: theme.borderWidthCursorBar)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMD))
    }
}
