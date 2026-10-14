import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct StatusBarView: View {
    let model: StatusModel
    let theme: ThemeTokens
    @State private var explainsMode = false

    public init(model: StatusModel, theme: ThemeTokens) {
        self.model = model
        self.theme = theme
    }

    public var body: some View {
        HStack(spacing: theme.space5) {
            if let text = model.safeModeText { modeChip(text) }
            if let sending = model.sendingLine { sendingButton(sending) }
            if let focus = model.focusLine {
                Text(focus)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            if let smart = model.smartSearchLine {
                Text(smart)
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .help("Smart search is indexing your mail on this Mac. Nothing leaves this Mac.")
            }
            if let preparing = model.preparingLine {
                Text(preparing)
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .help("Mail is preparing replies and summaries on this Mac. Nothing leaves this Mac.")
                    .accessibilityIdentifier("status.aiPreparing")
            }
            if let pending = model.pendingLine {
                Text(pending)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .help(model.pendingHelp)
                    .accessibilityIdentifier("status.pendingSync")
            }
            TimelineView(.periodic(from: .now, by: 20)) { context in
                if let sync = model.syncText(now: context.date) {
                    SyncLine(text: sync, color: syncColor)
                        .help(model.syncFailureCode.map { "Details: \($0)" } ?? "")
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
    }

    private func sendingButton(_ text: String) -> some View {
        Button {
            model.showSending?()
        } label: {
            HStack(spacing: theme.space2) {
                Image(systemName: "paperplane")
                    .font(.system(size: ShellMetrics.statusIconSize, weight: .regular))
                Text(text)
                    .font(theme.typeMeta.swiftUIFont)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.textSecondary.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the message on its way")
        .accessibilityLabel(text)
        .accessibilityHint("Shows the message on its way, with Undo while it can still be undone.")
        .accessibilityIdentifier("status.sending")
    }

    private var safeModeTooltip: String {
        [model.safeModeDetail.map { $0 + "." }, model.safeModeHelp].compactMap { $0 }.joined(separator: " ")
    }

    private func modeChip(_ text: String) -> some View {
        Button {
            explainsMode.toggle()
        } label: {
            HStack(spacing: theme.space2) {
                Image(systemName: Self.modeSymbol)
                    .font(.system(size: ShellMetrics.statusIconSize, weight: .regular))
                Text(text)
                    .font(theme.typeMeta.swiftUIFont)
                    .lineLimit(1)
            }
            .padding(.horizontal, theme.space3)
            .padding(.vertical, theme.space1)
            .background(Capsule().fill(theme.bgWarningSubtle.color))
            .foregroundStyle(theme.textWarning.color)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(safeModeTooltip)
        .popover(isPresented: $explainsMode, arrowEdge: .top) { modeExplanation(text) }
        .accessibilityLabel(text)
        .accessibilityHint("Shows what this mode allows. " + safeModeTooltip)
    }

    private func modeExplanation(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            Label(text, systemImage: Self.modeSymbol)
                .font(theme.typeBodyStrong.swiftUIFont)
                .foregroundStyle(theme.textWarning.color)
            if let detail = model.safeModeDetail {
                Text(detail + ".")
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let help = model.safeModeHelp {
                Text(help)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.space5)
        .frame(width: ShellMetrics.modePopoverWidth, alignment: .leading)
        .background(theme.component.popover.bg.color)
    }

    nonisolated static let modeSymbol = "lock.fill"

    private var syncColor: ThemeColor {
        guard let state = model.shownSync?.state else { return theme.textTertiary }
        switch state {
        case .online: return theme.textTertiary
        case .offline, .rateLimited, .syncFailing: return theme.textWarning
        case .needsReauth: return theme.textDanger
        }
    }
}

struct SyncLine: View {
    let text: String
    let color: ThemeColor
    @Environment(\.theme) private var theme
    @State private var shown: String?
    @State private var pollingSince: Date?

    var body: some View {
        Text(shown ?? text)
            .font(theme.typeMeta.swiftUIFont)
            .foregroundStyle(color.color)
            .lineLimit(1)
            .task(id: text) { await follow(text) }
    }

    private func follow(_ text: String) async {
        if text == StatusModel.pollingText, shown != nil {
            try? await Task.sleep(for: .milliseconds(Int(theme.motionSpinnerDelay)))
            guard !Task.isCancelled else { return }
            shown = text
            pollingSince = Date()
            return
        }
        if let since = pollingSince {
            let left = theme.motionSpinnerMinVisible / 1000 - Date().timeIntervalSince(since)
            if left > 0 {
                try? await Task.sleep(for: .milliseconds(Int(left * 1000)))
                guard !Task.isCancelled else { return }
            }
        }
        pollingSince = nil
        shown = text
    }
}
