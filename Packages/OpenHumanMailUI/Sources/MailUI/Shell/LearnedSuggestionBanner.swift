import MailFeatures
import MailModel
import SwiftUI

struct LearnedSuggestionBanner: View {
    let center: LearnedBehaviourCenter
    let suggestion: LearnedSuggestion
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
            Image(systemName: "lightbulb")
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.space1) {
                Text(suggestion.text)
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(center.errorMessage ?? "Learned on this Mac from what you do. Undo with ⌘Z; rules are in Settings › Importance.")
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle((center.errorMessage == nil ? theme.textTertiary : theme.textWarning).color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: theme.space3)
            Button(suggestion.actionTitle) { Task { await center.accept(suggestion) } }
                .ohLinkButtonStyle()
                .font(theme.typeLabel.swiftUIFont)
                .accessibilityHint("Adds a rule that keeps this mail out of Important. Undo with Command Z.")
            Button("Not now") { Task { await center.notNow(suggestion) } }
                .ohLinkButtonStyle()
                .font(theme.typeLabel.swiftUIFont)
        }
        .padding(.horizontal, theme.space5)
        .padding(.vertical, theme.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestion from what you do")
    }
}
