import MailFeatures
import MailTheme
import OpenHumanCore
import SwiftUI

public struct AIConsentView: View {
    let request: AIProviderConsentRequest
    let center: AICenter?
    let accept: () -> Void
    let decline: () -> Void
    @State private var onDeviceOnly: [AccountID: Bool]
    @Environment(\.theme) private var theme

    public init(request: AIProviderConsentRequest, center: AICenter?, accept: @escaping () -> Void, decline: @escaping () -> Void) {
        self.request = request
        self.center = center
        self.accept = accept
        self.decline = decline
        _onDeviceOnly = State(initialValue: Dictionary(uniqueKeysWithValues: request.accounts.map { ($0.id, $0.onDeviceOnly) }))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            Label(request.title, systemImage: "arrow.up.right")
                .font(theme.typeBodyStrong.swiftUIFont)
                .foregroundStyle(theme.textWarning.color)
            ForEach(Array(request.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(verbatim: paragraph)
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = request.learnMoreURL {
                Link(String(localized: "How Apple describes Private Cloud Compute"), destination: url)
                    .font(theme.typeLabel.swiftUIFont)
            }
            if let center, !request.accounts.isEmpty {
                VStack(alignment: .leading, spacing: theme.space2) {
                    ForEach(request.accounts) { account in
                        Toggle(isOn: Binding(get: { onDeviceOnly[account.id] ?? false }, set: { on in
                            onDeviceOnly[account.id] = on
                            try? center.setOnDeviceOnly(on, accountID: account.id)
                        })) {
                            Text("On-device AI only for \(account.title)")
                                .font(theme.typeBody.swiftUIFont)
                                .foregroundStyle(theme.textPrimary.color)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                }
                .padding(.vertical, theme.space2)
            }
            HStack(spacing: theme.space3) {
                Spacer(minLength: 0)
                Button(request.declineTitle, action: decline)
                Button(request.acceptTitle, action: accept)
            }
        }
        .padding(theme.space4)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgWarningSubtle.color))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(request.title)
    }
}
