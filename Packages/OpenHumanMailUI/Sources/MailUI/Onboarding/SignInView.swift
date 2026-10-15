import MailFeatures
import MailModel
import MailTheme
import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

public struct SignInView: View {
    @Bindable var model: SignInModel
    let theme: ThemeTokens
    @State private var importing = false
    @FocusState private var copyFocused: Bool
    @FocusState private var accountFocused: Bool
    @Environment(\.openURL) private var openURL

    public init(model: SignInModel, theme: ThemeTokens) {
        self.model = model
        self.theme = theme
    }

    public var body: some View {
        Group {
            if model.showsClientGuide {
                GoogleClientGuideView(guide: model.clientGuide, theme: theme, haveFile: { importing = true },
                                      skip: { model.closeClientGuide() })
            } else {
                ViewThatFits(in: .vertical) {
                    centredColumn.frame(maxHeight: .infinity)
                    ScrollView(.vertical) { centredColumn }
                }
            }
        }
        .background(theme.bgWindow.color)
        .task {
            #if canImport(AppKit)
            if model.pasteboard == nil { model.pasteboard = SystemPasteboard() }
            #endif
            await model.run()
        }
        .onChange(of: model.remoteURL) { _, url in if url != nil { copyFocused = true } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.importFailed()
                return
            }
            Task { await model.importClient(json: data) }
        }
    }

    private var centredColumn: some View {
        content
            .frame(idealWidth: SignInMetrics.column, maxWidth: SignInMetrics.column, alignment: .leading)
            .padding(SignInMetrics.padding)
            .frame(maxWidth: .infinity)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            main
            if model.showsKeychainNote {
                Text(model.keychainNote)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.phase == .remotePreparing || model.phase == .remotePaste || model.phase == .remoteCompleting {
                remoteStep
            }
            if let note = model.clientNote, model.errorMessage == nil {
                Text(note)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.errorMessage {
                let parts = Self.splitDetails(error)
                VStack(alignment: .leading, spacing: 6) {
                    Text(parts.message)
                        .font(theme.typeBody.swiftUIFont)
                        .foregroundStyle(theme.textDanger.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let details = parts.details {
                        Text(verbatim: "Details: \(details)")
                            .font(theme.typeMeta.swiftUIFont)
                            .foregroundStyle(theme.textTertiary.color)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !model.moreOptions.isEmpty {
                moreOptions
            }
        }
    }

    private var main: some View {
        let screen = model.screen
        return VStack(alignment: .leading, spacing: 12) {
            Text(screen.appName)
                .font(theme.typeLabel.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if model.phase == .signingIn || model.phase == .remotePreparing {
                    ProgressView().controlSize(.small)
                }
                Text(screen.sentence)
                    .font(theme.typeTitle.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if let action = screen.action, let title = screen.actionTitle {
                primaryButton(action, title: title)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private func primaryButton(_ action: SignInScreen.Action, title: String) -> some View {
        switch action {
        case .cancel:
            Button(title) { model.cancel() }
                .keyboardShortcut(.cancelAction)
        case .signIn, .setUpGoogle, .importClientFile:
            Button {
                switch action {
                case .signIn: model.signIn()
                case .setUpGoogle: model.openClientGuide()
                case .importClientFile: importing = true
                case .cancel: model.cancel()
                }
            } label: {
                Text(title)
                    .font(theme.typeBodyStrong.swiftUIFont)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(action == .signIn && !model.canSignIn)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            disclosure("More options", isExpanded: model.showsMoreOptions) { model.toggleMoreOptions() }
            if model.showsMoreOptions {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.moreOptions, id: \.self) { option in
                        moreOption(option)
                    }
                }
                .padding(.leading, SignInMetrics.optionsIndent)
            }
        }
    }

    @ViewBuilder
    private func moreOption(_ option: SignInMoreOption) -> some View {
        switch option {
        case .specificAccount:
            if model.showsAccountField {
                accountField
            } else {
                Button("Use a specific account…") {
                    model.useSpecificAccount()
                    accountFocused = true
                }
                .ohLinkButtonStyle()
            }
        case .anotherDevice:
            Button("Sign in from another device") { model.beginRemote() }
                .ohLinkButtonStyle()
                .help("Open the sign-in page on another device or in a browser that isn't on this Mac.")
        case .ownClient:
            ownClientDisclosure
        case .clientChoice:
            clientChoice
        case .haveClientFile:
            Button("I already have the file…") { importing = true }
                .ohLinkButtonStyle()
        case .clientFileHelp:
            Text(model.clientFixHint)
                .font(theme.typeMeta.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        case .whatMailAsksFor:
            accessInfo
        }
    }

    private func disclosure(_ title: String, isExpanded: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
                Text(title)
                    .font(theme.typeBody.swiftUIFont)
            }
            .foregroundStyle(theme.textSecondary.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var accessInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            disclosure("What does Mail ask for?", isExpanded: model.showsAccessInfo) { model.toggleAccessInfo() }
            if model.showsAccessInfo {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.accessText)
                        .font(theme.typeMeta.swiftUIFont)
                        .foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PermissionInfo.info(.gmail).whatBreaksIfDenied)
                        .font(theme.typeMeta.swiftUIFont)
                        .foregroundStyle(theme.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.calendarNote)
                        .font(theme.typeMeta.swiftUIFont)
                        .foregroundStyle(theme.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, SignInMetrics.optionsIndent)
            }
        }
    }

    public static func splitDetails(_ text: String) -> (message: String, details: String?) {
        guard let range = text.range(of: "\nDetails: ") else { return (text, nil) }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }

    private var clientChoice: some View {
        HStack(spacing: 12) {
            if model.showsClientPicker {
                Picker("Google client", selection: Binding(get: { model.selectedClient?.id ?? "" },
                                                           set: { id in Task { await model.selectClient(id) } })) {
                    ForEach(model.clients) { client in Text(verbatim: client.title).tag(client.id) }
                }
                .fixedSize()
                .disabled(model.phase != .ready)
            } else if let label = model.clientLabel {
                Text(verbatim: label)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
            }
            if model.canImportAnotherClient {
                Button("Import another client file…") { importing = true }
                    .ohLinkButtonStyle()
            }
        }
    }

    private var accountField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Account (optional)")
                .font(theme.typeLabel.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
            // Why: AppKit draws the field's own prompt in the accent colour, so the hint is drawn over the empty field
            TextField("Account (optional)", text: $model.loginHint, prompt: Text(verbatim: ""))
                .textFieldStyle(.roundedBorder)
                .overlay(alignment: .leading) {
                    if model.loginHint.isEmpty {
                        Text(verbatim: "name@example.com")
                            .font(theme.typeBody.swiftUIFont)
                            .foregroundStyle(theme.textTertiary.color)
                            .padding(.leading, SignInMetrics.fieldTextInset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .focused($accountFocused)
                .disabled(model.phase == .signingIn)
                .onSubmit { model.signIn() }
        }
    }

    private var ownClientDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            disclosure("Use my own Google client", isExpanded: model.showsOwnClient) { model.toggleOwnClient() }
            if model.showsOwnClient {
                Text(Self.ownClientText)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                if model.clientLabel != nil || model.canImportAnotherClient {
                    clientChoice
                }
                HStack(spacing: 16) {
                    Button("Import client file…") { importing = true }
                    Button("How to get one") { model.openClientGuide() }
                        .ohLinkButtonStyle()
                }
                googleStepsChecklist
            }
        }
    }

    private var googleStepsChecklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(GoogleClientGuide.title)
                .font(theme.typeLabel.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
            ForEach(Array(GoogleClientGuide.steps.enumerated()), id: \.element.id) { index, step in
                Text(verbatim: "\(index + 1). \(step.title): \(step.action)")
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var remoteStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = model.remoteURL {
                Text(Self.remoteText)
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical) {
                    Text(url.absoluteString)
                        .font(theme.typeMeta.swiftUIFont.monospaced())
                        .foregroundStyle(theme.textPrimary.color)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 150)
                .background(theme.bgWindow.color, in: RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 10) {
                    Button("Copy address") { model.copyRemoteAddress() }
                        .buttonStyle(.borderedProminent)
                        .focused($copyFocused)
                    Button("Open in browser") { openURL(url) }
                    if model.remoteAddressCopied {
                        Label("Copied", systemImage: "checkmark.circle.fill")
                            .font(theme.typeMeta.swiftUIFont)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    Spacer(minLength: 0)
                }
                TextField("Paste the whole address (it starts with http://127.0.0.1)", text: $model.pastedAddress)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.phase != .remotePaste)
                    .onSubmit { model.submitPasted() }
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Button("Cancel") { model.cancelRemote() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") { model.submitPasted() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.phase != .remotePaste
                        || model.pastedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.bgSunken.color, in: RoundedRectangle(cornerRadius: 8))
    }

    static let remoteText = "Open this address in a browser on another device and sign in; when it ends on an error page, "
        + "copy that page's whole address and paste it here."
    static let calendarNote = "Your calendar isn't part of this sign-in. It's a separate step afterwards, and you can "
        + "skip it."
    static let ownClientText = "Mail signs in with the Google client it has now. To use a Google Cloud project of your "
        + "own, import its client file, or pick one you imported before. Each account signs in with the client you pick "
        + "here; accounts already added keep theirs."

    static let accessText = "Mail asks Gmail for permission to read and change your mail: archive, star, label, snooze, "
        + "trash, save drafts and send. It never asks to delete mail permanently or to change Gmail settings or filters."
}

enum SignInMetrics {
    static let column: CGFloat = 440
    static let padding: CGFloat = 32
    static let fieldTextInset: CGFloat = 6
    static let optionsIndent: CGFloat = 16
}

#if canImport(AppKit)
@MainActor
final class SystemPasteboard: TextPasteboard {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
