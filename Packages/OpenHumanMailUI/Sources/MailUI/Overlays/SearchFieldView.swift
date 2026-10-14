import MailFeatures
import MailTheme
import SwiftUI

struct SearchFieldView: View {
    let search: SearchModel
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var cursor = 0
    @State private var dropdown = SearchDropdownState()
    @State private var pills: [SearchQueryToken] = []
    @State private var rest = ""

    var body: some View {
        let suggestions = search.suggestions
        let interpretation = search.interpretation.state
        let showsDropdown = dropdown.shows(focused: focused, hasContent: !suggestions.isEmpty || interpretation != .hidden)
        let highlighted = showsDropdown && suggestions.indices.contains(cursor) ? suggestions[cursor] : nil
        HStack(spacing: theme.space3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: ShellMetrics.smallIconSize + 1))
                .foregroundStyle(theme.textTertiary.color)
            ForEach(Array(pills.enumerated()), id: \.offset) { _, token in
                SearchTokenPill(token: token)
            }
            TextField("Search mail", text: Binding(get: { rest }, set: { typed($0) }),
                      prompt: Text(pills.isEmpty ? "Search mail — try from:dana has:attachment" : "")
                          .foregroundStyle(theme.textTertiary.color))
                .textFieldStyle(.plain)
                .font(theme.typeTab.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .overlayInputLine(theme.typeTab)
                .focused($focused)
                .onKeyPress(KeyEquivalent("j"), phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    return search.askAI() ? .handled : .ignored
                }
                .onSubmit {
                    if showsDropdown, suggestions.indices.contains(cursor), cursor > 0 || search.text.isEmpty {
                        search.accept(suggestions[cursor])
                    } else {
                        search.submit()
                    }
                }
                .overlayKeys(up: {
                                 if dropdown.closed { dropdown.open() } else { move(-1, count: suggestions.count) }
                             },
                             down: {
                                 if suggestions.isEmpty || dropdown.closed {
                                     if !search.focusResults(), !suggestions.isEmpty { dropdown.open() }
                                 } else {
                                     move(1, count: suggestions.count)
                                 }
                             },
                             escape: { escape(showingDropdown: showsDropdown) })
                .onKeyPress(.tab) { search.acceptInterpretation() ? .handled : .ignored }
                .onKeyPress(.delete) {
                    guard rest.isEmpty, let reopened = SearchQueryTokens.reopeningLast(search.text) else { return .ignored }
                    search.text = reopened
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command), search.canSearchGmail else { return .ignored }
                    search.searchGmail()
                    return .handled
                }
                .accessibilityLabel("Search mail")
            if !invalidOperators.isEmpty {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(theme.textWarning.color)
                    .help("Dates look like 2026/10/01")
                    .accessibilityLabel("A date operator has an invalid date")
            }
            if focused, !search.text.isEmpty {
                clearButton
            }
            KeycapView(text: "esc")
        }
        .padding(.horizontal, theme.space4)
        .frame(height: ShellMetrics.tabHeight)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
        .anchorPreference(key: SearchDropdownKey.self, value: .bounds) { field in
            showsDropdown ? SearchDropdownRequest(field: field, search: search, cursor: cursor) : nil
        }
        .onAppear {
            showPills(of: search.text)
            takeFocusIfAsked()
        }
        .onChange(of: search.focusRequest) { _, _ in takeFocusIfAsked() }
        .onChange(of: search.resultsFocusRequest) { _, _ in focused = false }
        .onChange(of: focused) { _, now in if now { dropdown.open() } }
        .onChange(of: search.text) { _, text in
            cursor = 0
            if SearchQueryTokens.join(pills, rest: rest) != text { showPills(of: text) }
        }

        .onChange(of: highlighted?.id) { _, _ in search.highlight(highlighted) }
        .task(id: search.text) { await search.refreshPeople() }
    }

    private var clearButton: some View {
        Button {
            search.text = ""
            dropdown.open()
            focused = true
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: ShellMetrics.smallIconSize + 1))
                .foregroundStyle(theme.textTertiary.color)
                .frame(width: ShellMetrics.smallIconSize + 9, height: ShellMetrics.smallIconSize + 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Clear (Esc)")
        .accessibilityLabel("Clear search")
        .accessibilityHint("Escape")
    }

    private func typed(_ newRest: String) {
        rest = newRest
        let text = SearchQueryTokens.join(pills, rest: newRest)
        if search.text != text { search.text = text }
        dropdown.open()
        if SearchQueryTokens.split(text).tokens.count > pills.count {
            // Deferred so SwiftUI shows the edit first; moving text into a pill in the same pass would keep the typed operator
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                showPills(of: search.text)
            }
        }
    }

    private func showPills(of text: String) {
        let parts = SearchQueryTokens.split(text)
        pills = parts.tokens
        rest = parts.rest
    }

    private var invalidOperators: [SearchToken] { search.tokens.filter { $0.isChip && !$0.isValid } }

    private func takeFocusIfAsked() {
        guard search.focusRequest != search.focusTaken else { return }
        focused = true
        dropdown.open()
        search.fieldTookFocus()
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        cursor = (cursor + delta + count) % count
    }

    private func escape(showingDropdown: Bool) {
        if dropdown.escape(showing: showingDropdown) {
            if search.interpretation.isShowing { search.interpretation.dismiss() }
        } else {
            search.escape()
        }
    }
}

struct InterpretationWaitingRow: View {
    @Environment(\.theme) private var theme
    @State private var showsLine = false

    var body: some View {
        HStack(spacing: theme.space4) {
            Image(systemName: "sparkle")
                .font(.system(size: 14))
                .frame(width: 18)
                .foregroundStyle(theme.textAI.color)
            Text("Understanding your search…")
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(theme.textTertiary.color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space4)
        .frame(height: 32)
        .overlay(alignment: .bottom) {
            if showsLine {
                Rectangle().fill(theme.textAI.color.opacity(0.6)).frame(height: 2).padding(.horizontal, theme.space4)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            showsLine = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Understanding your search")
    }
}

struct InterpretationRow: View {
    let plan: ResolvedSearchPlan
    let use: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: use) {
            HStack(spacing: theme.space4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14))
                    .frame(width: 18)
                    .foregroundStyle(theme.textAI.color)
                HStack(spacing: 4) {
                    ForEach(Array(plan.chips.enumerated()), id: \.offset) { _, chip in
                        Text(chip.title)
                            .font(theme.typeLabel.swiftUIFont)
                            .foregroundStyle(chip.kind == .note ? theme.textWarning.color : theme.textPrimary.color)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(RoundedRectangle(cornerRadius: theme.radiusPill)
                                .fill(chip.kind == .note ? theme.bgWarningSubtle.color : theme.bgAISubtle.color))
                    }
                }
                Spacer(minLength: 0)
                KeycapView(text: "⇥")
                Text("use")
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
            }
            .padding(.horizontal, theme.space4)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(plan.spokenSummary)
    }
}

struct SearchResultsHeader: View {
    let text: String
    var search: SearchModel? = nil
    @Environment(\.theme) private var theme
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: theme.space3) {
            Text(text)
                .font(theme.typeLabel.swiftUIFont)
                .foregroundStyle(theme.textTertiary.color)
                .accessibilityAddTraits(.isHeader)
            if let search, let draft = search.savedSearchNameDraft {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .padding(.horizontal, theme.space2)
                    .frame(maxWidth: 240, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
                    .focused($nameFocused)
                    .onAppear {
                        name = draft
                        nameFocused = true
                    }
                    .onSubmit { Task { await search.commitSavedSearchName(name) } }
                    .onKeyPress(.escape) {
                        search.cancelSavedSearchName()
                        return .handled
                    }
                    .accessibilityLabel("Saved search name")
            } else if let saved = search?.savedSummary {
                Text(saved)
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let smart = search?.smartSearchHeader {
                Text(smart.text)
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1)
                    .help(smart.help)
                    .accessibilityLabel(smart.text)
                    .accessibilityHint(smart.help)
            }
            if let search, search.canSaveShownSearch, search.savedSearchNameDraft == nil {
                Button("Save") { Task { await search.saveShownSearch() } }
                    .buttonStyle(.plain)
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle(theme.accentText.color)
                    .accessibilityLabel("Save this search")
            }
        }
        .padding(.horizontal, theme.space5)
        .padding(.vertical, theme.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: search?.shownQuery) { search?.followAccount() }
    }
}

struct SearchCoverageRow: View {
    let notice: SearchCoverageNotice
    let search: SearchModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space3) {
            if notice.isSearching {
                ProgressView().controlSize(.small)
            }
            Text(notice.text)
                .font(theme.typeLabel.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if notice.offersGmailSearch {
                Button(SearchCoverageNotice.searchGmailTitle) { search.searchGmail() }
                    .ohLinkButtonStyle()
                    .font(theme.typeLabel.swiftUIFont)
                    .help("Search Gmail  ⌘↩")
                    .accessibilityLabel(SearchCoverageNotice.searchGmailTitle)
                    .accessibilityHint(SearchCoverageNotice.searchGmailHint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space5)
        .padding(.bottom, theme.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search coverage")
    }
}
