import MailFeatures
import MailModel
import SwiftUI

struct SearchSheet: View {
    let phone: PhoneMail
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.touch) private var theme

    private var search: SearchModel { phone.search }

    var body: some View {
        VStack(spacing: 0) {
            field
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let suggestions = search.suggestions
                    if !suggestions.isEmpty {
                        ForEach(suggestions) { suggestion in
                            Button { accept(suggestion) } label: { SuggestionRow(suggestion: suggestion) }
                                .buttonStyle(.plain)
                        }
                    }
                    if phone.isSearching, let list = phone.list {
                        Rectangle().fill(theme.hairline).frame(height: theme.tokens.borderWidthHairline)
                            .padding(.vertical, theme.tokens.space2)
                        if let summary = search.resultsSummary {
                            Text(summary)
                                .font(theme.date)
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, theme.gutter)
                                .padding(.bottom, theme.tokens.space2)
                        }
                        ForEach(list.rows) { row in
                            Button { openResult(row.id) } label: {
                                ThreadRowView(row: row, chips: [], location: list.location, formatting: phone.formatting)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, theme.tokens.space8)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(theme.window.ignoresSafeArea())
        .onAppear { focused = !phone.isRendering }
        .task(id: search.text) { await search.refreshPeople() }
        .onDisappear {
            if !phone.isSearching { search.close() }
            phone.showsSearch = false
        }
    }

    private var field: some View {
        HStack(spacing: theme.tokens.space3) {
            HStack(spacing: theme.tokens.space2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
                TextField("", text: Binding(get: { search.text }, set: { search.text = $0 }),
                          prompt: Text("Search mail").foregroundStyle(theme.textTertiary))
                    .font(theme.body)
                    .foregroundStyle(theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit(submit)
                    .accessibilityLabel("Search mail")
                    .accessibilityIdentifier("search.field")
                if !search.text.isEmpty {
                    Button { search.text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the search")
                }
            }
            .padding(.horizontal, theme.tokens.space4)
            .frame(minHeight: 48)
            .background(Capsule().fill(theme.pill))
            .overlay(Capsule().strokeBorder(theme.elevatedBorder, lineWidth: theme.tokens.borderWidthHairline))
            Button("Cancel") { phone.closeSearch() }
                .font(theme.body)
                .foregroundStyle(theme.textLink)
                .accessibilityIdentifier("search.cancel")
        }
        .padding(.horizontal, theme.tokens.space4)
        .padding(.vertical, theme.tokens.space3)
    }

    private func submit() {
        search.submit()
        if phone.isSearching { dismiss() }
    }

    private func accept(_ suggestion: SearchSuggestion) {
        search.accept(suggestion)
        if phone.isSearching, search.text == phone.search.shownQuery { dismiss() }
        focused = true
    }

    private func openResult(_ key: ThreadKey) {
        dismiss()
        phone.open(key)
    }
}

struct SuggestionRow: View {
    let suggestion: SearchSuggestion
    @Environment(\.touch) private var theme

    var body: some View {
        HStack(spacing: theme.tokens.space3) {
            Image(systemName: symbol)
                .font(theme.smallIcon)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(theme.body)
                    .foregroundStyle(theme.textPrimary)
                if let detail = suggestion.detail {
                    Text(detail)
                        .font(theme.snippet)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.gutter)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(suggestion.group.rawValue)
    }

    private var symbol: String {
        switch suggestion.kind {
        case .recent: "clock.arrow.circlepath"
        case .person: "person"
        case .label: "tag"
        case .operator: "line.3.horizontal.decrease"
        case .saved: "bookmark"
        }
    }
}
