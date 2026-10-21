import MailFeatures
import SwiftUI

public enum AISettingsTab: String, CaseIterable, Sendable {
    case overview, prompts, activity

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .prompts: String(localized: "Prompts")
        case .activity: String(localized: "Activity")
        }
    }
}

public struct AISettingsTabs<Overview: View>: View {
    public typealias Tab = AISettingsTab

    @State private var tab: Tab
    @State private var prompts: PromptsSettingsModel?
    @State private var activity: AIActivityModel?
    private let navigator: SettingsNavigator?
    private let overview: Overview
    @Environment(\.theme) private var theme
    @Environment(\.settingsReveal) private var reveal

    public init(prompts: @autoclosure () -> PromptsSettingsModel?, activity: @autoclosure () -> AIActivityModel? = nil,
                navigator: SettingsNavigator? = nil, initialTab: Tab = .overview, @ViewBuilder overview: () -> Overview) {
        let model = prompts()
        let activityModel = activity()
        _prompts = State(initialValue: model)
        _activity = State(initialValue: activityModel)
        let offered = initialTab == .overview || (initialTab == .prompts && model != nil)
            || (initialTab == .activity && activityModel != nil)
        _tab = State(initialValue: offered ? initialTab : .overview)
        self.navigator = navigator
        self.overview = overview()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space7) {
            if tabs.count > 1 {
                Picker(String(localized: "AI settings"), selection: $tab) {
                    ForEach(tabs, id: \.self) { tab in Text(tab.title).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings.ai.tabs")
            }
            switch tab {
            case .overview: overview
            case .prompts:
                if let prompts { PromptsSettingsView(model: prompts) }
            case .activity:
                if let activity { AIActivityView(model: activity, editPrompt: prompts == nil ? nil : { editPrompt($0) }) }
            }
        }
        .task(id: navigator?.requestedPrompt) { await takeRequest() }
        .onChange(of: reveal, initial: true) { _, reveal in
            if reveal?.entry.page == SettingsPageID.ai.rawValue, let shown = reveal?.entry.tab.flatMap(Tab.init(rawValue:)),
               tabs.contains(shown) {
                tab = shown
            }
        }
    }

    private var tabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .overview: true
            case .prompts: prompts != nil
            case .activity: activity != nil
            }
        }
    }

    private func editPrompt(_ id: String) {
        guard let prompts else { return }
        tab = .prompts
        Task { await prompts.open(promptID: id) }
    }

    private func takeRequest() async {
        guard let prompts, let id = navigator?.takeRequestedPrompt() else { return }
        tab = .prompts
        await prompts.open(promptID: id)
    }
}
