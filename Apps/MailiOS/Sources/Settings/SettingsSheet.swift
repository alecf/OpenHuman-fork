import MailFeatures
import MailTheme
import MailUI
import SwiftUI

struct SettingsSheet: View {
    let phone: PhoneMail
    @Environment(ThemeStore.self) private var themes
    @Environment(\.touch) private var theme

    var body: some View {
        NavigationStack {
            Form {
                Section("Accounts") {
                    ForEach(phone.router.accounts) { state in
                        LabeledContent(state.account.displayName ?? "Account", value: state.account.email)
                    }
                    if phone.environment.isFake {
                        Label("Sample mail on this iPhone. Nothing reaches Google.", systemImage: "info.circle")
                            .font(theme.snippet)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                Section("Appearance") {
                    Picker("Theme", selection: appearance) {
                        Text("System").tag(AppearanceMode.system)
                        Text("Light").tag(AppearanceMode.light)
                        Text("Dark").tag(AppearanceMode.dark)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.appearance")
                }
                Section {
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("Build", value: BuildFlavor.name)
                } footer: {
                    Text("More settings come to iPhone in later updates.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.window)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { phone.showsSettings = false }
                }
            }
        }
    }

    private var appearance: Binding<AppearanceMode> {
        Binding(get: { themes.preferences.mode }, set: { mode in
            var next = themes.preferences
            next.mode = mode
            themes.preferences = next
        })
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
