import MailFeatures
import MailModel
import MailTheme
import SwiftUI

struct CleanupRulesSection: View {
    let model: CleanupRulesModel
    let canEdit: Bool

    var body: some View {
        SettingsSection(CleanupRulesModel.sectionTitle, footnote: CleanupRulesModel.note) {
            ForEach(model.entries) { entry in
                SettingsRow(entry.title, labelsControl: false) {
                    HStack(spacing: 8) {
                        Picker(entry.title, selection: Binding(get: { entry.choice },
                                                               set: { choice in Task { await model.set(entry.target, choice) } })) {
                            ForEach([ArchiveSuggestionOverride.always, .never], id: \.self) {
                                Text(CleanupRulesModel.title($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        Button { Task { await model.remove(entry.target) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove the choice for \(entry.title)")
                    }
                }
                .disabled(!canEdit)
            }
            CleanupAddRow(model: model)
                .disabled(!canEdit)
        }
    }
}

struct CleanupAddRow: View {
    static let title = "Add a sender or domain"
    static let prompt = "dana@example.com or example.com"

    let model: CleanupRulesModel
    @State private var draft = ""
    @State private var draftChoice: ArchiveSuggestionOverride = .never
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsRow(Self.title, status: model.addError, statusTone: .danger, stacked: true) {
            HStack(spacing: theme.space3) {
                TextField(Self.title, text: $draft, prompt: Text(verbatim: Self.prompt).settingsPrompt(theme))
                    .labelsHidden()
                    .settingsTextField()
                    .frame(maxWidth: .infinity)
                    .onSubmit(add)
                Picker("Choice", selection: $draftChoice) {
                    ForEach([ArchiveSuggestionOverride.always, .never], id: \.self) {
                        Text(CleanupRulesModel.title($0)).tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let text = draft, choice = draftChoice
        Task { if await model.add(text, choice: choice) { draft = "" } }
    }
}
