import MailFeatures
import MailModel
import SwiftUI

struct SavedSearchSettingsRows: View {
    let model: SavedSearchesModel
    @Environment(\.theme) private var theme
    @State private var renaming: String?
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    static let emptyNote = "None yet. Save a search from the results header, or with ⌘K › Save this search."

    var body: some View {
        if model.searches.isEmpty {
            SettingsRow("Saved searches", detail: Self.emptyNote)
        } else {
            ForEach(model.searches) { search in
                if renaming == search.id {
                    SettingsRow("Rename saved search", detail: search.query) {
                        TextField("Name", text: $draft, prompt: Text("Name").settingsPrompt(theme))
                            .settingsTextField()
                            .frame(width: 200)
                            .focused($nameFocused)
                            .onAppear { nameFocused = true }
                            .onSubmit { commit(search.id) }
                            .onKeyPress(.escape) {
                                renaming = nil
                                return .handled
                            }
                    }
                } else {
                    SettingsRow(search.name, detail: search.query) {
                        HStack(spacing: theme.space3) {
                            Button("Rename") {
                                draft = search.name
                                renaming = search.id
                            }
                            Button("Delete", role: .destructive) { Task { await model.delete(search.id) } }
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
            }
        }
        if let error = model.errorMessage {
            SettingsErrorLine(text: error)
        }
    }

    private func commit(_ id: String) {
        let name = draft
        renaming = nil
        Task { await model.rename(id, to: name) }
    }
}
