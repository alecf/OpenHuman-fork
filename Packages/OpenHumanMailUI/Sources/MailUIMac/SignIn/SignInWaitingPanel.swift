import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI

public struct SignInWaitingPanel: View {
    @Bindable var model: SignInWaitingModel
    @Environment(\.theme) private var theme

    public init(model: SignInWaitingModel) {
        self.model = model
    }

    public static let width: CGFloat = 440

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space4) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
                ProgressView().controlSize(.small)
                Text(model.title).themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let account = model.pending?.account {
                Text(verbatim: account).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                    .accessibilityLabel("For \(account)")
            }
            if let opened = model.openedLine {
                Text(opened).themeFont(theme.typeBody)
                    .foregroundStyle((model.pending?.openFailed == true ? theme.textWarning : theme.textSecondary).color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let copied = model.copiedNote {
                Text(copied).themeFont(theme.typeMeta).foregroundStyle(theme.textSuccess.color)
            }
            if model.showsLink, let url = model.pending?.url {
                Text(verbatim: url.absoluteString)
                    .themeFont(theme.typeCaption)
                    .foregroundStyle(theme.textPrimary.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(theme.space3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgSunken.color))
                    .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
                        .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
                    .accessibilityIdentifier("signin.wait.link")
            }
            if let error = model.errorMessage {
                Text(error).themeFont(theme.typeMeta).foregroundStyle(theme.textDanger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: theme.space3) {
                moreOptions
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { Task { await model.cancel() } }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("signin.wait.cancel")
            }
        }
        .padding(theme.space6)
        .frame(width: Self.width, alignment: .leading)
        .background(theme.bgWindow.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("signin.wait")
    }

    private var moreOptions: some View {
        Menu {
            Button("Open in default browser") { Task { await model.openInDefaultBrowser() } }
                .accessibilityIdentifier("signin.wait.default")
            if !model.browsers.isEmpty {
                Section("Open in") {
                    ForEach(model.browsers) { browser in
                        Button { Task { await model.open(in: browser.id) } } label: {
                            Label {
                                Text(verbatim: browser.id == model.remembered ? "\(browser.name) (last used)"
                                                                              : browser.name)
                            } icon: {
                                Image(nsImage: Self.icon(browser.appPath))
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Copy sign-in link") { model.copyLink() }
                .accessibilityIdentifier("signin.wait.copy")
            Button(model.showsLink ? "Hide the link" : "Show the link") { model.toggleLink() }
                .accessibilityIdentifier("signin.wait.show")
        } label: {
            Text("More options")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(SignInWaitingModel.thisMacNote)
        .accessibilityIdentifier("signin.wait.openIn")
    }

    static func icon(_ path: String) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
