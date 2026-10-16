import MailFeatures
import MailTheme
import OpenHumanAI
import SwiftUI

public struct AIFeatureModelsSection: View {
    @State private var choices: [AIModelChoiceModel]
    @State private var background: [AIBackgroundModel] = []
    private let center: AICenter
    private let reloadKey: Int
    @Environment(\.theme) private var theme

    public static let features: [AIFeature] = [.rewrite, .askInbox, .replyOptions, .summarize, .classify]

    public init(center: AICenter, reloadKey: Int = 0, onTriageChange: (@MainActor () async -> Void)? = nil) {
        self.center = center
        self.reloadKey = reloadKey
        _choices = State(initialValue: Self.features.map { feature in
            let choice = AIModelChoiceModel(center: center, feature: feature, accountKey: nil)
            if feature == .classify { choice.onChange = onTriageChange }
            return choice
        })
    }

    public var body: some View {
        let shown = choices.filter { !$0.options.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            if !shown.isEmpty || !background.isEmpty { section(shown) }
        }
        .task(id: reloadKey) { await reload() }
    }

    private func reload() async {
        for choice in choices { await choice.refresh() }
        background = await center.backgroundModels()
    }

    private func section(_ shown: [AIModelChoiceModel]) -> some View {
        SettingsSection(String(localized: "Model for each feature"), footnote: Self.footnote) {
            ForEach(shown, id: \.feature) { choice in
                row(choice).accessibilityIdentifier("settings.ai.model.\(choice.feature.rawValue)")
            }
            ForEach(background) { item in
                SettingsRow(item.title, detail: item.detail) {
                    Text(verbatim: item.model)
                        .themeFont(theme.typeBody)
                        .foregroundStyle(theme.textSecondary.color)
                }
                .accessibilityIdentifier("settings.ai.model.background.\(item.id)")
            }
        }
    }

    @ViewBuilder private func row(_ choice: AIModelChoiceModel) -> some View {
        let title = AITraceWording.feature(choice.feature)
        if choice.isFixed {
            SettingsRow(title, detail: [choice.why, choice.onlyChoiceText].compactMap { $0 }.joined(separator: ". "),
                        status: choice.note, statusTone: .warning) {
                HStack(spacing: theme.space2) {
                    Text(verbatim: choice.chosenName ?? choice.options.first?.name ?? "")
                        .themeFont(theme.typeBody)
                        .foregroundStyle(theme.textSecondary.color)
                    if choice.options.first?.isDefault == true { AIDefaultTag() }
                }
            }
        } else {
            SettingsRow(title, detail: choice.why, status: choice.note, statusTone: .warning,
                        selection: Binding(get: { choice.chosen ?? "" }, set: { id in Task { await choice.choose(id) } })) {
                ForEach(choice.options) { option in
                    Text(verbatim: Self.label(option, chosen: option.id == choice.chosen))
                        .tag(option.id)
                        .selectionDisabled(!option.isEnabled)
                        .disabled(!option.isEnabled)
                }
            }
        }
    }

    static func label(_ option: AIModelChoiceModel.Option, chosen: Bool) -> String {
        var text = option.isDefault ? String(localized: "\(option.name) (default)") : option.name
        if !chosen, let status = option.status { text += " — " + status }
        return text
    }

    static let footnote = String(localized: "Each feature uses only the model chosen here; if it isn't ready, Mail says why and doesn't try another. Work Mail does in the background, like triage and one-line summaries, stays on this Mac. A model that needs your OK can be allowed under Models.")
}
