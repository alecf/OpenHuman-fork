import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import UniformTypeIdentifiers

struct SplitSettingsPage: View {
    @State private var model: SplitSettingsModel
    @State private var confirmDelete: SplitInfo?
    @Environment(\.theme) private var theme

    init(environment: AppEnvironment) {
        self.init(model: SplitSettingsModel(environment: environment))
    }

    init(model: SplitSettingsModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        SettingsPageScaffold(title: "Split inbox") {
            if model.accounts.count > 1 {
                SettingsSection {
                    SettingsRow("Account", detail: "Each account has its own splits.", selection: $model.account) {
                        ForEach(model.accounts) { Text($0.alias ?? $0.email).tag(Optional($0.id)) }
                    }
                }
            }
            if let note = model.availability.storedItemsNote { SettingsFootnote(note, tone: .warning) }
            SettingsSection("Splits", footnote: SplitSettingsModel.tabOptionsNote) {
                List {
                    ForEach(model.splits) { split in
                        HStack(spacing: theme.space3) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(theme.textTertiary.color).accessibilityHidden(true)
                            Text(split.name).themeFont(theme.typeBodyStrong).foregroundStyle(theme.textPrimary.color)
                            Text(SplitSettingsModel.ruleSummary(split.ruleText)).themeFont(theme.typeMeta).monospaced()
                                .foregroundStyle(theme.textSecondary.color)
                                .lineLimit(1)
                                .help(split.ruleText)
                                .accessibilityLabel(split.ruleText)
                            Spacer()
                            if split.unreadThreads > 0 {
                                Text(SplitSettingsModel.unreadTitle(split.unreadThreads)).themeFont(theme.typeMeta)
                                    .foregroundStyle(theme.textTertiary.color)
                            }
                            if model.isHiddenWhenEmpty(split) {
                                Text("Hidden when empty").themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
                            }
                            if model.isAlsoShownInInbox(split) {
                                Text("Also in Important/Other").themeFont(theme.typeMeta)
                                    .foregroundStyle(theme.textTertiary.color)
                            }
                            tabOptions(isOn: model.isHiddenWhenEmpty(split), set: { hidden in
                                Task { await model.setHiddenWhenEmpty(split, hidden) }
                            }, alsoShow: Binding(get: { model.isAlsoShownInInbox(split) },
                                                 set: { on in Task { await model.setAlsoShownInInbox(split, on) } }))
                            rowMenu {
                                Button("Edit") { model.beginEdit(split) }
                                Button("Delete", role: .destructive) { confirmDelete = split }
                            }
                            .disabled(!model.canEdit)
                        }
                        .frame(height: 32)
                    }
                    .onMove { source, destination in Task { await model.move(from: source, to: destination) } }
                    .moveDisabled(!model.canEdit)
                    HStack(spacing: theme.space3) {
                        Image(systemName: "lock").foregroundStyle(theme.textTertiary.color).accessibilityHidden(true)
                        Text("Other").themeFont(theme.typeBodyStrong).foregroundStyle(theme.textPrimary.color)
                        Text(SplitSettingsModel.otherNote).themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
                        Spacer()
                        if model.otherTotal != nil, let unread = model.otherUnread, unread > 0 {
                            Text(SplitSettingsModel.unreadTitle(unread))
                                .themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
                        }
                        if model.isOtherHiddenWhenEmpty {
                            Text("Hidden when empty").themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
                        }
                        tabOptions(isOn: model.isOtherHiddenWhenEmpty) { hidden in
                            Task { await model.setOtherHiddenWhenEmpty(hidden) }
                        }
                        rowMenu { EmptyView() }
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    .frame(height: 32)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(model.splits.count + 1) * Self.listRowHeight)
                .padding(.vertical, theme.space2)
            }
            if model.draft != nil { editor } else {
                HStack(spacing: theme.space3) {
                    Button("Add split…") { model.beginAdd() }.disabled(!model.canEdit)
                    presetMenu
                }
            }
            eventsSection
            SettingsErrorLine(text: model.errorMessage)
        }
        .task { model.start() }
        .alert("Delete this split?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let split = confirmDelete { Task { await model.delete(split) } }
                confirmDelete = nil
            }
        } message: {
            Text("Its conversations move to the next tab that matches, or to Other. Nothing changes in Gmail.")
        }
    }

    @ViewBuilder private var eventsSection: some View {
        if model.eventsOffer != nil || model.eventsChange != nil || model.canRescanEvents {
            SettingsSection("Events") {
                VStack(alignment: .leading, spacing: theme.space2) {
                    if let offer = model.eventsOffer {
                        Text(offer.explanation).themeFont(theme.typeBody).foregroundStyle(theme.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: theme.space3) {
                        if let offer = model.eventsOffer {
                            Button(offer.buttonTitle) { Task { await model.acceptEventsOffer() } }
                        }
                        if model.eventsChange != nil {
                            Button("Undo") { Task { await model.undoEventsChange() } }
                        }
                        Button("Re-scan for invites") { Task { await model.rescanEvents() } }
                            .disabled(!model.canRescanEvents)
                            .help("Sorts your inbox again with the current event rules. Invitations whose message is not "
                                + "downloaded yet are checked a few at a time by the next syncs.")
                        Spacer()
                    }
                    if let note = model.eventsNote {
                        Text(note).themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
                    }
                }
                .padding(.vertical, theme.space2)
            }
        }
    }

    private func tabOptions(isOn: Bool, set: @escaping (Bool) -> Void, alsoShow: Binding<Bool>? = nil) -> some View {
        Menu {
            Toggle("Hide this tab when it has no mail", isOn: Binding(get: { isOn }, set: set))
            if let alsoShow { Toggle("Also show in Important/Other", isOn: alsoShow) }
        } label: {
            Image(systemName: isOn ? "eye.slash" : "eye")
                .foregroundStyle(isOn ? theme.textSecondary.color : theme.textTertiary.color)
        }
            .ohBorderlessMenuStyle().fixedSize()
            .tint(isOn ? theme.textSecondary.color : theme.textTertiary.color)
            .help("Tab options")
            .accessibilityLabel("Tab options")
            .accessibilityValue(isOn ? "Hides when empty" : "Always shown")
            .disabled(!model.canHideWhenEmpty)
    }

    private func rowMenu<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
        Menu(content: items) { Image(systemName: "ellipsis").foregroundStyle(theme.textSecondary.color) }
            .ohBorderlessMenuStyle().fixedSize()
            .tint(theme.textSecondary.color)
            .accessibilityLabel("More actions for this split")
    }

    private var presetMenu: some View {
        Menu("Add preset…") {
            ForEach(model.presets) { preset in
                Button {
                    model.beginPreset(preset)
                } label: {
                    Text(model.existingSplit(for: preset) == nil ? preset.name : "\(preset.name) (already added)")
                    Text(preset.summary)
                }
                .help(preset.summary)
            }
        }
        .menuStyle(.button).fixedSize()
        .disabled(!model.canEdit)
        .help(model.presetsUnavailableReason ?? "Fill the editor with a ready-made split; you check the count and save it.")
    }

    static let listRowHeight: CGFloat = 40

    private var editor: some View {
        SettingsSection(model.draft?.id == nil ? "New split" : "Edit split") {
            VStack(alignment: .leading, spacing: theme.space3) {
                TextField("Name", text: Binding(get: { model.draft?.name ?? "" }, set: { model.draft?.name = $0 }),
                          prompt: Text("Name").settingsPrompt(theme))
                    .settingsTextField().frame(maxWidth: 320)
                TextField("Rule", text: Binding(get: { model.draft?.ruleText ?? "" }, set: { model.draft?.ruleText = $0; model.updatePreview() }),
                          prompt: Text(verbatim: "For example from:(@acme.example) OR label:Clients").settingsPrompt(theme))
                    .settingsTextField().monospaced()
                if let preview = model.preview { SettingsFootnote(preview) }
                HStack(spacing: theme.space3) {
                    Button("Cancel") { model.cancelEdit() }
                    Button("Save") { Task { await model.save() } }.buttonStyle(.borderedProminent).disabled(!model.canSave)
                }
            }
            .settingsRowPadding()
        }
    }
}

struct SnippetSettingsPage: View {
    @State private var model: SnippetSettingsModel
    @State private var transfer: SnippetTransferModel
    @State private var exporting: SettingsFileDocument?
    @State private var importing = false
    @State private var transferNote: String?
    @State private var addingFiles = false
    @Environment(\.theme) private var theme

    init(environment: AppEnvironment) {
        _model = State(initialValue: SnippetSettingsModel(environment: environment))
        _transfer = State(initialValue: SnippetTransferModel(environment: environment))
    }

    var body: some View {
        SettingsPageScaffold(title: "Snippets", layout: .fill) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: theme.space3) {
                    TextField("Search snippets", text: $model.searchText, prompt: Text("Search snippets").settingsPrompt(theme))
                        .settingsTextField()
                    List(model.visible, selection: selection) { snippet in
                        HStack {
                            Text(snippet.name).themeFont(theme.typeBody).foregroundStyle(theme.textPrimary.color)
                            Spacer()
                            if let shortcut = snippet.shortcut {
                                KeycapView(text: ";;" + shortcut)
                            }
                        }
                        .frame(height: 28)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(snippet.name)
                        .accessibilityValue(snippet.shortcut.map { ";;" + $0 } ?? "")
                    }
                    .scrollContentBackground(.hidden)
                    if model.snippets.isEmpty { SettingsFootnote(SnippetSettingsModel.emptyText) }
                    Button("New snippet") { model.beginNew() }.disabled(!model.canEdit)
                    if let note = model.availability.storedItemsNote { SettingsFootnote(note, tone: .warning) }
                    snippetFile
                }
                .padding(theme.space4)
                .frame(width: 220)
                .frame(maxHeight: .infinity, alignment: .top)
                Rectangle().fill(theme.borderHairline.color).frame(width: theme.borderWidthHairline)
                editor.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgSunken.color))
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusLG))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
                .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
        }
        .task { model.start() }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting, contentType: .json, defaultFilename: "Mail snippets") { result in
            if case .failure = result {
                transferNote = "The file couldn't be saved."
            } else {
                transferNote = transfer.message.map { "Snippets exported. " + $0 } ?? "Snippets exported."
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task { await prepareImport(url) }
        }
        .alert("Delete this snippet?", isPresented: Binding(get: { model.confirmingDelete != nil },
                                                            set: { if !$0 { model.cancelDelete() } })) {
            Button("Cancel", role: .cancel) { model.cancelDelete() }
            Button("Delete", role: .destructive) { Task { await model.confirmDelete() } }
        } message: {
            Text("It is removed from this Mac.")
        }
    }

    @ViewBuilder
    private var snippetFile: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            Button("Export Snippets…") { Task { await exportSnippets() } }
                .disabled(model.snippets.isEmpty)
                .accessibilityIdentifier("settings.snippets.export")
            Button("Import Snippets…") { importing = true }
                .disabled(!model.canEdit)
                .accessibilityIdentifier("settings.snippets.import")
            if let preview = transfer.preview {
                Text(preview.summary).themeFont(theme.typeMeta).foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = preview.detail { SettingsFootnote(detail) }
                if preview.shortcutsDropped > 0 {
                    SettingsFootnote("\(preview.shortcutsDropped) shortcut(s) are already used here and are left off.")
                }
                if let note = preview.storedItemsNote { SettingsFootnote(note, tone: .warning) }
                HStack(spacing: theme.space3) {
                    Button("Cancel") { transfer.cancelImport() }
                    Button("Import") { Task { transferNote = await transfer.applyImport() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview.isEmpty || preview.storedItemsNote != nil)
                }
            }
            if let transferNote { SettingsFootnote(transferNote) }
        }
    }

    private func exportSnippets() async {
        do {
            exporting = SettingsFileDocument(data: try await transfer.export())
        } catch {
            transferNote = "The snippets couldn't be read."
        }
    }

    private func prepareImport(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            transferNote = "That file couldn't be read."
            return
        }
        do {
            _ = try await transfer.prepareImport(data)
            transferNote = nil
        } catch {
            transferNote = (error as? SnippetTransferError)?.description ?? "That file couldn't be read."
        }
    }

    private var selection: Binding<SnippetInfo.ID?> {
        Binding(get: { model.draft.flatMap { $0.isNew ? nil : $0.id } },
                set: { id in if let snippet = model.visible.first(where: { $0.id == id }) { model.beginEdit(snippet) } })
    }

    @ViewBuilder
    private var editor: some View {
        if let draft = model.draft {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space3) {
                    Text(draft.isNew ? "New snippet" : "Edit snippet").themeFont(theme.typeHeadline)
                        .foregroundStyle(theme.textPrimary.color)
                        .accessibilityAddTraits(.isHeader)
                    field("Name") {
                        TextField("Name", text: Binding(get: { model.draft?.name ?? "" }, set: { model.draft?.name = $0 }),
                                  prompt: Text("Name").settingsPrompt(theme))
                    }
                    field("Shortcut") {
                        TextField("Shortcut", text: Binding(get: { model.draft?.shortcut ?? "" }, set: { model.draft?.shortcut = $0 }),
                                  prompt: Text("Typed after ;;").settingsPrompt(theme))
                    }
                    SettingsErrorLine(text: model.shortcutConflict)
                    recipientFields
                    field("Subject") {
                        TextField("Subject", text: Binding(get: { model.draft?.subject ?? "" }, set: { model.draft?.subject = $0 }),
                                  prompt: Text("Optional").settingsPrompt(theme))
                    }
                    field("Body") {
                        TextEditor(text: Binding(get: { model.draft?.body ?? "" }, set: { model.draft?.body = $0 }))
                            .themeFont(theme.typeReader)
                            .scrollContentBackground(.hidden)
                            .padding(theme.space2)
                            .frame(minHeight: 160)
                            .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgWindow.color))
                            .overlay(RoundedRectangle(cornerRadius: theme.radiusMD)
                                .strokeBorder(theme.borderControl.color, lineWidth: theme.borderWidthControl))
                            .accessibilityLabel("Body")
                    }
                    if draft.hadFormatting {
                        SettingsFootnote("This snippet has formatting. Saving it here keeps the text and drops the formatting.",
                                         tone: .warning)
                    }
                    variablesTable
                    filesSection
                    HStack(spacing: theme.space3) {
                        Button("Delete", role: .destructive) { model.askToDelete(draft.id) }.disabled(draft.isNew || !model.canEdit)
                        Spacer(minLength: 0)
                        Button("Cancel") { model.cancelEdit() }
                        Button("Save") { Task { await model.save() } }.buttonStyle(.borderedProminent).disabled(!model.canSave)
                    }
                    SettingsErrorLine(text: model.errorMessage)
                }
                .padding(theme.space5)
            }
            .fileImporter(isPresented: $addingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { await addFiles(urls) }
            }
        } else {
            Text("Choose a snippet or make a new one.").themeFont(theme.typeBody).foregroundStyle(theme.textSecondary.color)
                .padding(theme.space5)
        }
    }

    @ViewBuilder
    private var recipientFields: some View {
        field("To") {
            TextField("To", text: Binding(get: { model.draft?.to ?? "" }, set: { model.draft?.to = $0 }),
                      prompt: Text("Optional: added when the snippet is inserted").settingsPrompt(theme))
        }
        field("Cc") {
            TextField("Cc", text: Binding(get: { model.draft?.cc ?? "" }, set: { model.draft?.cc = $0 }),
                      prompt: Text("Optional").settingsPrompt(theme))
        }
        field("Bcc") {
            TextField("Bcc", text: Binding(get: { model.draft?.bcc ?? "" }, set: { model.draft?.bcc = $0 }),
                      prompt: Text("Optional").settingsPrompt(theme))
        }
        SettingsErrorLine(text: model.recipientProblem)
    }

    @ViewBuilder
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            Text("Files").settingsSectionLabel(theme)
            ForEach(model.draft?.attachments ?? [], id: \.self) { file in
                HStack(spacing: theme.space2) {
                    Image(systemName: "paperclip").font(.system(size: 11)).accessibilityHidden(true)
                    Text(file.filename).lineLimit(1).truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                        .foregroundStyle(theme.textTertiary.color)
                    Spacer(minLength: 0)
                    Button { model.removeAttachment(file) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canEdit)
                    .accessibilityLabel("Remove \(file.filename)")
                }
                .themeFont(theme.typeMeta)
                .foregroundStyle(theme.textSecondary.color)
                .padding(.horizontal, theme.space2)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgWindow.color))
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: theme.space3) {
                Button("Add Files…") { addingFiles = true }
                    .disabled(!model.canEdit || model.isAddingFiles)
                    .accessibilityIdentifier("settings.snippets.addFiles")
                if model.isAddingFiles { ProgressView().controlSize(.small) }
            }
            SettingsFootnote("Inserting the snippet attaches these files. Up to 10 MB each, 25 MB together.")
        }
    }

    private func addFiles(_ urls: [URL]) async {
        let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
        defer { for (url, ok) in zip(urls, scoped) where ok { url.stopAccessingSecurityScopedResource() } }
        await model.addFiles(urls)
    }

    private func field<Field: View>(_ name: String, @ViewBuilder _ content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: theme.space1) {
            Text(name).themeFont(theme.typeLabel).foregroundStyle(theme.textSecondary.color).accessibilityHidden(true)
            content().labelsHidden().settingsTextField()
        }
    }

    @ViewBuilder
    private var variablesTable: some View {
        let variables = model.variables
        if !variables.isEmpty {
            VStack(alignment: .leading, spacing: theme.space2) {
                Text("Variables").settingsSectionLabel(theme)
                ForEach(variables, id: \.name) { variable in
                    HStack(spacing: theme.space3) {
                        Text("{{\(variable.name)}}").themeFont(theme.typeMono).foregroundStyle(theme.textPrimary.color)
                            .frame(width: 120, alignment: .leading)
                        if variable.isBuiltIn {
                            Text("filled automatically").themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                        } else {
                            TextField("Default for \(variable.name)", text: Binding(get: { model.draft?.defaults[variable.name] ?? "" },
                                                                                set: { model.setDefault($0, for: variable.name) }),
                                      prompt: Text("Default").settingsPrompt(theme))
                                .labelsHidden()
                                .settingsTextField()
                        }
                    }
                }
            }
        }
    }
}
