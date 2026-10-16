import MailFeatures
import MailTheme
import SwiftUI

public struct UpdateCheckSheet: View {
    let center: UpdateCheckCenter
    @Environment(\.theme) private var theme

    public static let width: CGFloat = 460

    public init(center: UpdateCheckCenter) {
        self.center = center
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space5) {
            HStack(alignment: .top, spacing: theme.space4) {
                badge
                VStack(alignment: .leading, spacing: theme.space2) {
                    Text(verbatim: message.headline)
                        .themeFont(theme.typeTitle)
                        .foregroundStyle(theme.textPrimary.color)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: message.detail)
                        .themeFont(theme.typeBody)
                        .foregroundStyle(theme.textSecondary.color)
                    if let early = center.earlyDevelopmentLine {
                        Text(verbatim: early)
                            .themeFont(theme.typeMeta)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let release = center.available, !release.noteLines.isEmpty {
                notes(release)
            }
            Text(verbatim: UpdateCheck.privacyNote)
                .themeFont(theme.typeMeta)
                .foregroundStyle(theme.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
            buttons
        }
        .padding(theme.space7)
        .frame(width: Self.width, alignment: .leading)
        .background(theme.bgWindow.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("updates.sheet")
    }

    private var message: UpdateCheckMessage {
        center.message ?? UpdateCheck.checking
    }

    @ViewBuilder private var badge: some View {
        if center.isChecking || center.phase == .idle {
            ProgressView()
                .controlSize(.regular)
                .frame(width: Self.badgeSize, height: Self.badgeSize)
                .accessibilityLabel(UpdateCheck.checking.headline)
        } else {
            Image(systemName: Self.symbol(message.tone))
                .font(.system(size: Self.badgeSize * 0.8, weight: .regular))
                .foregroundStyle(color(message.tone))
                .frame(width: Self.badgeSize, height: Self.badgeSize)
                .accessibilityHidden(true)
        }
    }

    static let badgeSize: CGFloat = 36

    static func symbol(_ tone: UpdateCheckMessage.Tone) -> String {
        switch tone {
        case .good: "checkmark.circle.fill"
        case .news: "arrow.down.circle.fill"
        case .neutral: "clock"
        case .attention: "exclamationmark.triangle"
        }
    }

    private func color(_ tone: UpdateCheckMessage.Tone) -> Color {
        switch tone {
        case .good: theme.textSuccess.color
        case .news: theme.accentText.color
        case .neutral: theme.textSecondary.color
        case .attention: theme.textWarning.color
        }
    }

    private func notes(_ release: UpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            Text("From the release notes")
                .themeFont(theme.typeLabel)
                .foregroundStyle(theme.textTertiary.color)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(release.noteLines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .themeFont(theme.typeBody)
                    .foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgSunken.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
            .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "Release notes: " + release.noteLines.joined(separator: " ")))
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: theme.space3) {
            Spacer(minLength: 0)
            switch center.phase {
            case .idle, .checking:
                Button("Close") { center.close() }
                    .keyboardShortcut(.cancelAction)
            case .finished(.available(let release)):
                Button("Not Now") { center.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { center.download() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Opens the release page in your browser")
                    .accessibilityLabel(Text(verbatim: "Download version \(release.version.displayName)"))
                    .accessibilityHint(Text(verbatim: "Opens the release page in your browser"))
            case .finished(.upToDate):
                Button("OK") { center.close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .finished:
                Button("Close") { center.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { center.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(Text(verbatim: "Check for updates again"))
            }
        }
    }
}
