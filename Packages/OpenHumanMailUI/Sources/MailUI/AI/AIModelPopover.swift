import MailFeatures
import MailTheme
import OpenHumanAI
import SwiftUI

struct AIComposerModelButton: View {
    let model: AIComposerModel
    let badge: AIProviderBadge
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            AIComposerModelBadgeLabel(badge: badge).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "The model behind this answer: change it, run again or see the trace"))
        .accessibilityLabel(String(localized: "Model for this answer"))
        .accessibilityIdentifier("composer.ai.model")
        .popover(isPresented: $open, arrowEdge: .bottom) { AIComposerModelPopover(model: model) }
    }
}

struct AIComposerModelBadgeLabel: View {
    let badge: AIProviderBadge
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            AIProviderBadgeView(badge: badge, short: true)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(theme.textTertiary.color)
        }
    }
}

struct AIComposerModelPopover: View {
    let model: AIComposerModel
    @State private var choice: AIModelChoiceModel?
    @State private var detail: AITraceDetail?
    @State private var showsTrace = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AITracePopoverFrame {
            if showsTrace, let detail {
                AITraceDetailView(detail: detail, backTitle: String(localized: "Model"), back: { showsTrace = false })
            } else {
                AIModelPopoverContent(
                    answerModel: detail?.model ?? model.currentVersion?.badge?.short ?? "",
                    answerBadge: detail?.badge ?? model.currentVersion?.badge,
                    answerFacts: detail.map(Self.numbers) ?? [],
                    choice: choice, canRerun: model.canRerun, hasTrace: detail != nil,
                    rerun: {
                        model.retry()
                        dismiss()
                    },
                    openTrace: { showsTrace = true })
            }
        }
        .task { await load() }
        .accessibilityIdentifier("composer.ai.modelPopover")
    }

    static func numbers(_ detail: AITraceDetail) -> [AITraceDetail.Fact] {
        detail.facts.filter { ["prompt", "time", "tokens"].contains($0.key) }
    }

    private func load() async {
        guard let center = model.aiCenter else { return }
        let choice = AIModelChoiceModel(center: center, feature: .rewrite, accountKey: model.accountKey)
        await choice.refresh()
        self.choice = choice
        if let id = model.currentVersion?.traceID, let trace = try? await center.traces?.trace(id) {
            detail = AITraceDetail(trace, why: await center.whyLine(for: trace))
        }
    }
}

struct AIModelPopoverContent: View {
    let answerModel: String
    let answerBadge: AIProviderBadge?
    let answerFacts: [AITraceDetail.Fact]
    let choice: AIModelChoiceModel?
    let canRerun: Bool
    let hasTrace: Bool
    let rerun: () -> Void
    let openTrace: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space4) {
            VStack(alignment: .leading, spacing: theme.space2) {
                Text("This answer").settingsSectionLabel(theme)
                HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
                    Text(verbatim: answerModel)
                        .themeFont(theme.typeBodyStrong)
                        .foregroundStyle(theme.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: theme.space2)
                    if let answerBadge { AIProviderBadgeView(badge: answerBadge, short: true) }
                }
                if !answerFacts.isEmpty { AITraceFactsView(facts: answerFacts, labelWidth: 64) }
            }
            Divider()
            if let choice {
                VStack(alignment: .leading, spacing: theme.space2) {
                    Text(verbatim: choice.title).settingsSectionLabel(theme)
                    ForEach(choice.options) { option in
                        AIModelOptionRow(option: option, chosen: option.id == choice.chosen) {
                            Task { await choice.choose(option.id) }
                        }
                    }
                    Text(verbatim: choice.why)
                        .themeFont(theme.typeMeta)
                        .foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("composer.ai.modelWhy")
                    if let only = choice.onlyChoiceText {
                        Text(verbatim: only)
                            .themeFont(theme.typeMeta)
                            .foregroundStyle(theme.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = choice.note {
                        Text(verbatim: note)
                            .themeFont(theme.typeMeta)
                            .foregroundStyle(theme.textWarning.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(verbatim: AIModelChoiceModel.futureRewrites)
                        .themeFont(theme.typeMeta)
                        .foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("composer.ai.modelScope")
                }
                Divider()
            }
            VStack(alignment: .leading, spacing: theme.space1) {
                AIPopoverRowButton(title: String(localized: "Re-run on this model"), symbol: "arrow.clockwise",
                                   detail: choice.flatMap { c in c.options.first { $0.id == c.chosen }?.name },
                                   enabled: canRerun, action: rerun)
                    .accessibilityIdentifier("composer.ai.rerun")
                AIPopoverRowButton(title: String(localized: "View trace"), symbol: "doc.text.magnifyingglass",
                                   detail: hasTrace ? String(localized: "Prompt, email text and answer as sent")
                                                    : String(localized: "No trace kept for this answer"),
                                   enabled: hasTrace, action: openTrace)
                    .accessibilityIdentifier("composer.ai.viewTrace")
            }
        }
    }
}

struct AIModelOptionRow: View {
    let option: AIModelChoiceModel.Option
    let chosen: Bool
    let choose: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accentText.color)
                    .opacity(chosen ? 1 : 0)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: theme.space2) {
                        Text(verbatim: option.name).themeFont(theme.typeBody).foregroundStyle(theme.textPrimary.color)
                        if option.isDefault { AIDefaultTag() }
                    }
                    if let status = option.status {
                        Text(verbatim: option.isEnabled ? status : status + Self.placeHint(status))
                            .themeFont(theme.typeMeta)
                            .foregroundStyle((option.isEnabled ? theme.textWarning : theme.textTertiary).color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: theme.space2)
                Image(systemName: option.badge.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle((option.badge.leavesMac ? theme.textWarning : theme.textTertiary).color)
                    .help(option.badge.title)
            }
            .padding(.horizontal, theme.space2)
            .padding(.vertical, theme.space2)
            .background(RoundedRectangle(cornerRadius: theme.radiusSM)
                .fill(hovered && option.isEnabled ? theme.bgRowHover.color : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
        .opacity(option.isEnabled ? 1 : 0.6)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("ai.model.option.\(option.id.rawValue)")
    }

    static func placeHint(_ status: String) -> String {
        status == String(localized: "needs your OK") || status == String(localized: "not downloaded")
            ? " " + String(localized: "in Settings › AI") : ""
    }
}

struct AIDefaultTag: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("Default")
            .themeFont(theme.typeCaption)
            .foregroundStyle(theme.accentText.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(theme.accentSubtle.color))
            .overlay(Capsule().strokeBorder(theme.accentText.color.opacity(0.35), lineWidth: theme.borderWidthHairline))
            .accessibilityLabel(String(localized: "Mail's default"))
    }
}
