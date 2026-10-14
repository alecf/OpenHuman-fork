import MailFeatures
import MailTheme
import SwiftUI

public struct BannerView: View {
    let banner: StatusBanner
    let action: (() -> Void)?
    @Environment(\.theme) private var theme

    public init(banner: StatusBanner, action: (() -> Void)? = nil) {
        self.banner = banner
        self.action = action
    }

    public var body: some View {
        HStack(spacing: theme.space3) {
            Image(systemName: banner.symbol)
                .font(.system(size: ShellMetrics.rowIconSize, weight: .regular))
            Text(banner.message)
                .font(theme.typeBody.swiftUIFont)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(banner.detail.map { "Details: \($0)" } ?? "")
            Spacer(minLength: theme.space5)
            if let title = banner.actionTitle, let action {
                Button(title, action: action)
                    .buttonStyle(.plain)
                    .font(theme.typeLabel.swiftUIFont)
            }
        }
        .foregroundStyle(foreground.color)
        .padding(.horizontal, theme.space7)
        .frame(height: theme.component.banner.height)
        .frame(maxWidth: .infinity)
        .background(background.color)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear { AccessibilityNotification.Announcement(banner.message).post() }
    }

    private var background: ThemeColor {
        switch banner.tone {
        case .danger: theme.bgDangerSubtle
        case .warning: theme.bgWarningSubtle
        case .neutral: theme.bgSunken
        }
    }

    private var foreground: ThemeColor {
        switch banner.tone {
        case .danger: theme.textDanger
        case .warning: theme.textWarning
        case .neutral: theme.textSecondary
        }
    }
}
