import MailFeatures
import MailTheme
import OpenHumanAI
import SwiftUI

public struct AIActivityView: View {
    @Bindable var model: AIActivityModel
    @State private var confirmsClear = false
    @Environment(\.theme) private var theme

    public init(model: AIActivityModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let detail = model.detail {
                AITraceDetailView(detail: detail, backTitle: model.page.title, back: { model.closeDetail() },
                                  delete: { Task { await model.delete(detail.id) } })
            } else {
                SettingsSectionStack {
                    list
                    retention
                    SettingsErrorLine(text: model.error)
                }
            }
        }
        .task { await model.refresh() }
        .accessibilityIdentifier("settings.ai.activity")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: theme.space4) {
            HStack(spacing: theme.space4) {
                Picker(String(localized: "Show"), selection: $model.page) {
                    ForEach(AIActivityModel.Page.allCases, id: \.self) { page in Text(page.title).tag(page) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings.ai.activity.page")
                if model.page == .feedback {
                    Toggle(String(localized: "Thumbs down only"), isOn: $model.onlyThumbsDown)
                        .ohCheckboxToggleStyle()
                        .themeFont(theme.typeBody)
                        .accessibilityIdentifier("settings.ai.activity.thumbsDown")
                }
                Spacer(minLength: theme.space3)
                Text(verbatim: model.summary)
                    .themeFont(theme.typeMeta)
                    .foregroundStyle(theme.textSecondary.color)
            }
            SettingsSection(footnote: AIActivityModel.note, compact: true) {
                let rows = model.rows
                if rows.isEmpty {
                    Text(verbatim: model.emptyText)
                        .themeFont(theme.typeBody)
                        .foregroundStyle(theme.textSecondary.color)
                        .settingsRowPadding()
                } else {
                    ForEach(rows) { row in
                        AIActivityRowView(row: row) { Task { await model.open(row.id) } }
                    }
                }
            }
        }
    }

    private var retention: some View {
        SettingsSection(String(localized: "Traces"), footnote: AIActivityModel.retentionNote) {
            SettingsRow(String(localized: "Keep a trace of each AI request"),
                        detail: String(localized: "Turn off to stop saving new traces. Ratings need a trace."),
                        isOn: $model.keepsTraces)
            Group {
                SettingsRow(String(localized: "Keep for"), selection: $model.keepDays) {
                    ForEach(Self.withCurrent(AIActivityModel.keepDaysChoices, model.keepDays), id: \.self) { days in
                        Text(AIActivityModel.days(days)).tag(days)
                    }
                }
                SettingsRow(String(localized: "Per feature, keep the newest"), selection: $model.perFeatureLimit) {
                    ForEach(Self.withCurrent(AIActivityModel.perFeatureChoices, model.perFeatureLimit), id: \.self) { count in
                        Text(verbatim: "\(count)").tag(count)
                    }
                }
                SettingsRow(String(localized: "Use at most"), selection: $model.maxBytes) {
                    ForEach(Self.withCurrent(AIActivityModel.sizeChoices, model.maxBytes), id: \.self) { bytes in
                        Text(AIActivityModel.size(bytes)).tag(bytes)
                    }
                }
                DisclosureGroup(String(localized: "Features to trace")) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(AIFeature.allCases, id: \.self) { feature in
                            SettingsRow(AITraceWording.feature(feature),
                                        isOn: Binding(get: { model.keeps(feature) }, set: { model.setKeeps(feature, $0) }))
                        }
                    }
                    .padding(.leading, theme.space4)
                }
                .themeFont(theme.typeBody)
                .settingsRowPadding()
                .accessibilityIdentifier("settings.ai.activity.features")
            }
            .disabled(!model.keepsTraces)
            HStack(spacing: theme.space3) {
                Spacer(minLength: 0)
                Button(String(localized: "Clear AI cache")) { Task { await model.clearCache() } }
                    .help(String(localized: "Drops saved summaries and replies, so the next ones are written again."))
                Button(String(localized: "Clear all traces…")) { confirmsClear = true }
                    .disabled(model.traces.isEmpty)
                    .accessibilityIdentifier("settings.ai.activity.clearAll")
            }
            .settingsRowPadding()
        }
        .confirmationDialog(AIActivityModel.clearConfirmTitle, isPresented: $confirmsClear) {
            Button(String(localized: "Clear All Traces"), role: .destructive) { Task { await model.clearAll() } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(AIActivityModel.clearConfirmDetail)
        }
    }

    static func withCurrent(_ choices: [Int], _ current: Int) -> [Int] {
        choices.contains(current) ? choices : (choices + [current]).sorted()
    }
}

struct AIActivityRowView: View {
    let row: AIActivityModel.Row
    let open: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: theme.space3) {
                Text(row.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .themeFont(theme.typeMeta)
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: 104, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.feature)
                        .themeFont(theme.typeBody)
                        .foregroundStyle((row.failed ? theme.textDanger : theme.textPrimary).color)
                        .lineLimit(1)
                    Text(verbatim: [row.model, row.numbers].filter { !$0.isEmpty }.joined(separator: " · "))
                        .themeFont(theme.typeMeta)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: theme.space3)
                if row.cacheHit {
                    Text("Saved")
                        .themeFont(theme.typeCaption)
                        .foregroundStyle(theme.textTertiary.color)
                        .help(String(localized: "A saved answer was reused; the model didn't run"))
                }
                if let rating = row.rating, rating != 0 {
                    Image(systemName: rating > 0 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary.color)
                        .accessibilityLabel(AITraceWording.rating(rating) ?? "")
                }
                Image(systemName: row.badge.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle((row.badge.leavesMac ? theme.textWarning : theme.textTertiary).color)
                    .help(row.badge.title)
                    .accessibilityLabel(row.badge.title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary.color)
            }
            .padding(.vertical, theme.space2)
            .padding(.horizontal, theme.space1)
            .frame(minHeight: SettingsMetrics.rowMinHeight)
            .background(RoundedRectangle(cornerRadius: theme.radiusSM)
                .fill(hovered ? theme.bgRowHover.color : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "Opens the full trace"))
        .accessibilityIdentifier("settings.ai.activity.row")
    }
}

public struct AIFeatureModelsSection: View {
    @State private var choices: [AIModelChoiceModel]

    public static let features: [AIFeature] = [.rewrite, .askInbox, .replyOptions, .summarize]

    public init(center: AICenter) {
        _choices = State(initialValue: Self.features.map { AIModelChoiceModel(center: center, feature: $0, accountKey: nil) })
    }

    public var body: some View {
        let shown = choices.filter { !$0.options.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            if !shown.isEmpty { section(shown) }
        }
        .task { for choice in choices { await choice.refresh() } }
    }

    private func section(_ shown: [AIModelChoiceModel]) -> some View {
        SettingsSection(String(localized: "Model for each feature"), footnote: Self.footnote) {
            ForEach(shown, id: \.feature) { choice in
                SettingsRow(AITraceWording.feature(choice.feature), detail: choice.why,
                            selection: Binding(get: { choice.chosen ?? "" },
                                               set: { id in Task { await choice.choose(id) } })) {
                    ForEach(choice.options) { option in
                        Text(option.isDefault ? String(localized: "\(option.name) (default)") : option.name).tag(option.id)
                    }
                }
                .accessibilityIdentifier("settings.ai.model.\(choice.feature.rawValue)")
            }
        }
    }

    static let footnote = String(localized: "Each feature uses only the model chosen here. If that model isn't ready, Mail says why and doesn't try another. One-line summaries, triage, search and follow-up checks always run on this Mac.")
}
