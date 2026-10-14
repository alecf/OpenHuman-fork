import MailFeatures
import MailTheme
import SwiftUI

struct HintBarView: View {
    let model: HintBarModel
    let theme: ThemeTokens

    var body: some View {
        let hints = model.hints.filter(\.isEnabled)
        ViewThatFits(in: .horizontal) {
            row(hints)
            row(Array(hints.prefix(ShellMetrics.narrowHintCount)))
        }
        .help("Shortcut hints for where you are. Turn them off in Settings › General, or right-click here.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shortcut hints")
    }

    private func row(_ hints: [ShortcutHint]) -> some View {
        HStack(spacing: theme.space5) {
            ForEach(hints) { hint in
                HStack(spacing: theme.space2) {
                    KeycapRow(keycaps: hint.keycaps)
                    Text(hint.title)
                        .font(theme.typeLabel.swiftUIFont)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(hint.title), \(hint.keycaps.joined(separator: " "))")
            }
        }
        .fixedSize()
    }
}
