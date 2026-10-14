import MailFeatures
import SwiftUI

public struct AISettingsTabs<Overview: View>: View {
    public enum Tab: String, CaseIterable, Sendable {
        case overview, prompts

        var title: String {
            switch self {
            case .overview: String(localized: "Overview")
            case .prompts: String(localized: "Prompts")
            }
        }
    }

    @State private var tab: Tab
    @State private var prompts: PromptsSettingsModel?
    private let navigator: SettingsNavigator?
    private let overview: Overview
    @Environment(\.theme) private var theme

    public init(prompts: @autoclosure () -> PromptsSettingsModel?, navigator: SettingsNavigator? = nil,
                initialTab: Tab = .overview, @ViewBuilder overview: () -> Overview) {
        let model = prompts()
        _prompts = State(initialValue: model)
        _tab = State(initialValue: model == nil ? .overview : initialTab)
        self.navigator = navigator
        self.overview = overview()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space7) {
            if prompts != nil {
                Picker(String(localized: "AI settings"), selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { tab in Text(tab.title).tag(tab) }
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
            }
        }
        .task(id: navigator?.requestedPrompt) { await takeRequest() }
    }

    private func takeRequest() async {
        guard let prompts, let id = navigator?.takeRequestedPrompt() else { return }
        tab = .prompts
        await prompts.open(promptID: id)
    }
}
