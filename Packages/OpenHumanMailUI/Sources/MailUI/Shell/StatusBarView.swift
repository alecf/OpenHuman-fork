import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct StatusBarView: View {
    let model: StatusModel
    let theme: ThemeTokens

    public init(model: StatusModel, theme: ThemeTokens) {
        self.model = model
        self.theme = theme
    }

    public var body: some View {
        HStack(spacing: theme.space5) {
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
