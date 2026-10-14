import MailFeatures
import MailModel
import SwiftUI

struct CleanupRulesSection: View {
    let model: CleanupRulesModel
    let canEdit: Bool
    @State private var draft = ""
    @State private var draftChoice: ArchiveSuggestionOverride = .never

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
            SettingsRow("Add a sender or domain", status: model.addError, statusTone: .danger) {
                HStack(spacing: 8) {
                    TextField("Add a sender or domain", text: $draft, prompt: Text("dana@example.com or example.com"))
                        .labelsHidden()
                        .frame(minWidth: 200)
                        .onSubmit(add)
                    Picker("Choice", selection: $draftChoice) {
                        ForEach([ArchiveSuggestionOverride.always, .never], id: \.self) {
                            Text(CleanupRulesModel.title($0)).tag($0)
                        }
                    }
                    .labelsHidden()
                    Button("Add", action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .disabled(!canEdit)
        }
    }

    private func add() {
        let text = draft, choice = draftChoice
        Task { if await model.add(text, choice: choice) { draft = "" } }
    }
}
