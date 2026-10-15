import MailFeatures
import MailTheme
import SwiftUI

public struct FooterView: View {
    let status: StatusModel?
    let hints: HintBarModel?
    let theme: ThemeTokens

    public init(status: StatusModel?, hints: HintBarModel?, theme: ThemeTokens) {
        self.status = status
        self.hints = hints
        self.theme = theme
    }

    public static func isVisible(status: StatusModel?, hints: HintBarModel?) -> Bool {
        hints?.isVisible == true || status?.isVisible == true
    }

    public var body: some View {
        let footer = theme.component.footer
        let showsHints = hints?.isVisible == true
        HStack(spacing: theme.space5) {
            Spacer(minLength: 0)
            if let hints, showsHints {
                HStack(spacing: theme.space2) {
                    HintBarView(model: hints, theme: theme)
                    closeButton(hints)
                }
            }
            Spacer(minLength: 0)
            if let status { StatusBarView(model: status, theme: theme) }
        }
        .padding(.horizontal, theme.space5)
        .frame(height: theme.footerHeight)
        .frame(maxWidth: .infinity)
        .background(footer.bg.color)
        .overlay(alignment: .top) {
            Rectangle().fill(footer.divider.color).frame(height: theme.borderWidthHairline)
        }
        .contextMenu {
            if let hints, showsHints {
                Button("Hide Shortcut Hints") { Task { await hints.dismiss() } }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func closeButton(_ hints: HintBarModel) -> some View {
        Button {
            Task { await hints.dismiss() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: ShellMetrics.statusIconSize, weight: .light))
                .foregroundStyle(theme.textTertiary.color)
                .frame(width: theme.footerHeight, height: theme.footerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hide shortcut hints (Settings > General brings them back)")
        .accessibilityLabel("Hide shortcut hints")
    }
}
