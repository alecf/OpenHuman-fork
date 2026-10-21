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
    @State private var query = ""
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

    private var results: [SettingsSearchResult] {
        SettingsSearch.results(for: query, pages: pages, includesDeveloperItems: hosting.showsDeveloperItems)
    }

    public var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(pages: pages, selection: $shell.selected, query: $query, results: results,
                            open: { shell.openResult($0.entry) }, build: hosting.build)
            Rectangle().fill(theme.borderHairline.color).frame(width: theme.borderWidthHairline)
            page
                .environment(\.settingsReveal, shell.reveal)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.bgWindow.color)
        .navigationTitle(shell.selectedEntry?.title ?? "Settings")
        .onAppear { followRequest() }
        .onChange(of: environment?.settingsNavigator.requestedPage) { followRequest() }
        .task(id: shell.reveal?.serial) {
            guard let serial = shell.reveal?.serial else { return }
            try? await Task.sleep(for: .seconds(SettingsMetrics.revealSeconds))
            if !Task.isCancelled { shell.endReveal(serial) }
        }
    }

    private func followRequest() {
        guard let navigator = environment?.settingsNavigator else { return }
        shell.takeRequest(from: navigator)
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
        case .sidebar: SidebarSettingsPage(environment: environment)
        case .shortcuts: ShortcutsSettingsPage(environment: environment, printText: hosting.printText)
        case .snippets: SnippetSettingsPage(environment: environment)
        case .search: SearchSettingsPage(environment: environment)
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
    @Binding var query: String
    var results: [SettingsSearchResult]
    var open: (SettingsSearchResult) -> Void
    var build: BuildLabel?
    @State private var cursor: String?
    @State private var opened: String?
    @FocusState private var focused: Bool
    @FocusState private var searching: Bool
    @Environment(\.theme) private var theme

    init(pages: [SettingsPageEntry], selection: Binding<String>, query: Binding<String> = .constant(""),
         results: [SettingsSearchResult] = [], open: @escaping (SettingsSearchResult) -> Void = { _ in },
         build: BuildLabel? = nil) {
        self.pages = pages
        _selection = selection
        _query = query
        self.results = results
        self.open = open
        self.build = build
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsSearchField(query: $query, focused: $searching, up: { moveCursor(by: -1) },
                                down: { moveCursor(by: 1) }, submit: openCursor)
                .padding([.horizontal, .top], theme.space3)
            if query.isEmpty { pageList } else { resultList }
            if let build {
                SettingsBuildFooter(build: build)
            }
        }
        .frame(width: SettingsMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(theme.bgSidebar.color)
        .background {
            Button("Search settings") { searching = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: query) {
            cursor = results.first?.id
            opened = nil
        }
    }

    private var pageList: some View {
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
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(characters: .alphanumerics, phases: .down) { press in startSearch(press) }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings pages")
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: theme.space1) {
                    if results.isEmpty {
                        Text("No results for \u{201C}\(query)\u{201D}")
                            .themeFont(theme.typeMeta)
                            .foregroundStyle(theme.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(theme.space3)
                            .accessibilityIdentifier("settings.search.empty")
                    }
                    ForEach(results) { result in
                        SettingsSearchResultRow(result: result, isSelected: result.id == opened,
                                                showsCursor: searching && result.id == cursor) { choose(result) }
                            .id(result.id)
                    }
                }
                .padding(theme.space3)
            }
            .onChange(of: cursor) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings search results")
    }

    private func move(by offset: Int) -> KeyPress.Result {
        if let next = Self.page(after: selection, offset: offset, in: pages.map(\.id)) { selection = next }
        return .handled
    }

    private func startSearch(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.subtracting([.shift, .capsLock]).isEmpty else { return .ignored }
        query = press.characters
        searching = true
        return .handled
    }

    private func moveCursor(by offset: Int) {
        let ids = results.map(\.id)
        if let current = cursor, let next = Self.page(after: current, offset: offset, in: ids) {
            cursor = next
        } else if cursor == nil || !ids.contains(cursor ?? "") {
            cursor = ids.first
        }
    }

    private func openCursor() {
        guard let result = results.first(where: { $0.id == cursor }) ?? results.first else { return }
        choose(result)
    }

    private func choose(_ result: SettingsSearchResult) {
        cursor = result.id
        opened = result.id
        open(result)
    }

    static func page(after current: String, offset: Int, in ids: [String]) -> String? {
        guard let index = ids.firstIndex(of: current) else { return ids.first }
        let target = min(max(index + offset, 0), ids.count - 1)
        return target == index ? nil : ids[target]
    }
}

struct SettingsSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let up: () -> Void
    let down: () -> Void
    let submit: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: SettingsMetrics.sidebarIconSize))
                .foregroundStyle(theme.textTertiary.color)
                .accessibilityHidden(true)
            TextField("Search settings", text: $query, prompt: Text("Search").settingsPrompt(theme))
                .textFieldStyle(.plain)
                .themeFont(theme.typeBody)
                .labelsHidden()
                .focused(focused)
                .onSubmit(submit)
                .onKeyPress(.upArrow) { up(); return .handled }
                .onKeyPress(.downArrow) { down(); return .handled }
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
                .accessibilityIdentifier("settings.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: SettingsMetrics.sidebarIconSize))
                        .foregroundStyle(theme.textTertiary.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, theme.space2)
        .frame(height: SettingsMetrics.sidebarRowHeight)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgWindow.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusMD)
            .strokeBorder((focused.wrappedValue ? theme.accentRing : theme.borderControl).color,
                          lineWidth: theme.borderWidthControl))
    }
}

struct SettingsSearchResultRow: View {
    let result: SettingsSearchResult
    let isSelected: Bool
    let showsCursor: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
                Image(systemName: result.symbol)
                    .font(.system(size: SettingsMetrics.sidebarIconSize))
                    .foregroundStyle((isSelected ? theme.accentText : theme.textSecondary).color)
                    .frame(width: theme.space6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(result.entry.title)
                        .themeFont(isSelected ? theme.typeBodyStrong : theme.typeBody)
                        .foregroundStyle(theme.textPrimary.color)
                    if let location = result.location {
                        Text(location)
                            .themeFont(theme.typeMeta)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space3)
            .padding(.vertical, theme.space1)
            .frame(minHeight: SettingsMetrics.sidebarRowHeight)
            .background(plate)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel([result.entry.title, result.location].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.search.result")
    }

    private var plate: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(isSelected ? theme.bgRowSelected.color : (hovering ? theme.bgRowHover.color : .clear))
            if showsCursor {
                Rectangle().fill(theme.accentRing.color).frame(width: theme.borderWidthCursorBar)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMD))
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

struct SettingsSidebarRow: View {
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
