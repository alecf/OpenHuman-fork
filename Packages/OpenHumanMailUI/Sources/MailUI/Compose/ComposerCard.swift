import MailActions
import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct ComposerCard<Editor: View>: View {
    let session: ComposeSession
    let manager: ComposeManager
    let editor: Editor
    let onClose: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.composerReveal) private var reveal

    public init(session: ComposeSession, manager: ComposeManager, onClose: @escaping () -> Void,
                @ViewBuilder editor: () -> Editor) {
        self.session = session
        self.manager = manager
        self.onClose = onClose
        self.editor = editor()
    }

    private var fieldRule: some View {
        Divider().overlay(theme.borderHairline.color)
    }

    private var isDocked: Bool {
        if case .docked = session.placement { true } else { false }
    }

    private var rowHeight: CGFloat { isDocked ? ComposerMetrics.dockedFieldHeight : ComposerMetrics.fieldHeight }

    public var body: some View {
        let compose = theme.component.compose
        VStack(alignment: .leading, spacing: 0) {
            if isDocked { draftLine } else { titleRow }
            ComposerBanners(session: session, manager: manager)
            let recentMail = manager.recentMailLookup(for: session)
            RecipientRow(field: session.to, session: session, rowHeight: rowHeight, inlinePopovers: isDocked,
                         recentMailLookup: recentMail,
                         historyLookup: manager.recipientHistoryLookup(for: session),
                         openConversations: { address in manager.searchConversations(with: address, from: session) },
                         autofocus: (session.mode == .new || session.mode == .forward) && session.to.tokens.isEmpty) {
                fieldButtons
            }
            if session.isRecipientRowShown(.cc) {
                fieldRule
                RecipientRow(field: session.cc, session: session, rowHeight: rowHeight, inlinePopovers: isDocked,
                             recentMailLookup: recentMail, autofocus: false) { EmptyView() }
            }
            if session.isRecipientRowShown(.bcc) {
                fieldRule
                RecipientRow(field: session.bcc, session: session, rowHeight: rowHeight, inlinePopovers: isDocked,
                             recentMailLookup: recentMail, autofocus: false) { EmptyView() }
            }
            fieldRule
            FromLine(session: session, manager: manager, rowHeight: rowHeight)
            if session.showsSubject {
                fieldRule
                subjectRow
            }
            fieldRule
            if Self.drawsQuickReplies(session, manager: manager), let strip = manager.instantReply(for: session) {
                InstantReplyStrip(model: strip)
                    .padding(.top, theme.space3)
            }
            editor
                .overlay(alignment: .bottomLeading) {
                    if !isDocked, let picker = session.snippetPicker {
                        SnippetPickerView(picker: picker, showsSearchField: session.snippetTriggerRange == nil)
                            .offset(y: 8)
                    }
                }
            if let mention = session.mentionPicker {
                MentionPickerView(picker: mention)
                    .padding(.bottom, theme.space3)
            }
            if let panel = session.aiPanel {
                AIComposerPanel(model: panel, center: manager.aiCenter)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ComposerPanelFrameKey.self,
                                                   value: geometry.frame(in: .named(ComposerReveal.space)))
                        }
                    }
                    .padding(.top, theme.space2)
                    .padding(.bottom, theme.space3)
                    .id(ComposerReveal.panelID)
            }
            if isDocked, let picker = session.snippetPicker {
                SnippetPickerView(picker: picker, showsSearchField: session.snippetTriggerRange == nil)
                    .padding(.bottom, theme.space3)
            }
            SignatureAndQuote(session: session, inline: isDocked)
            if !session.fileAttachments.isEmpty { AttachmentChips(session: session) }
            if let notice = session.notice {
                NoticeLine(notice: notice, sendAgain: { manager.perform(.send, in: session) }) { session.notice = nil }
            }
            if manager.showsFormatBar, !session.isPlainText {
                FormatBarView(state: session.formatState, style: .inline) { session.applyFormat($0) }
                    .padding(.bottom, theme.space1)
            }
            Divider().overlay(theme.borderHairline.color)
            ComposerActionBar(session: session, manager: manager)
        }
        .padding(isDocked ? EdgeInsets(top: theme.space4, leading: 0, bottom: theme.space1, trailing: 0)
                          : EdgeInsets(top: compose.padding, leading: compose.padding, bottom: compose.padding,
                                       trailing: compose.padding))
        .frame(maxWidth: compose.maxWidth)
        .background {
            if !isDocked {
                RoundedRectangle(cornerRadius: compose.radius).fill(compose.bg.color).themeShadow(compose.shadow)
            }
        }
        .overlay {
            if !isDocked {
                RoundedRectangle(cornerRadius: compose.radius)
                    .strokeBorder(theme.borderElevated.color, lineWidth: theme.borderWidthHairline)
            }
        }
        .overlay {
            if session.isLinkConfirmationShown {
                LinkConfirmationCard(session: session, manager: manager)
            } else if let card = session.sendConfirmation {
                SendConfirmationCard(session: session, manager: manager, card: card)
            }
        }
        .background(ComposerShortcuts(session: session, manager: manager, onClose: onClose))
        .background {
            if isDocked, session.aiPanel == nil, let strip = manager.instantReply(for: session), strip.showsRow,
               strip.phase == .ready {
                InstantReplyShortcuts(model: strip)
            }
        }
        .environment(\.actionDescriptors, manager.actionDescriptors)
        .onAppear { manager.attachInstantReply(session) }
        .onKeyPress(.escape) {
            if session.mentionPicker != nil { session.dismissMention(); return .handled }
            if session.snippetPicker != nil { session.closeSnippetPicker(); return .handled }
            if let panel = session.aiPanel { panel.close(); return .handled }
            if session.isLinkConfirmationShown { session.editLinkRecipients(); return .handled }
            if session.sendConfirmation != nil { session.cancelSendConfirmation(); return .handled }
            if manager.instantReply(for: session)?.handle(.clear) == true { return .handled }
            onClose()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.title)
        .coordinateSpace(name: ComposerReveal.space)
        .onPreferenceChange(ComposerPanelFrameKey.self) { frame in
            guard let frame else { return }
            MainActor.assumeIsolated { reveal?.action(frame) }
        }
    }

    private var draftLine: some View {
        let isAuto = isAutoDraft
        let parts = DraftLine.parts(isAuto: isAuto, names: session.recipientSummary)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(verbatim: parts.lead)
                    .foregroundStyle(theme.textSuccess.color)
                    .fixedSize()
                if let rest = parts.rest {
                    Text(verbatim: " " + rest)
                        .foregroundStyle(theme.textPrimary.color)
                        .truncationMode(.tail)
                }
            }
            .lineLimit(1)
            .font(theme.typeReader.swiftUIFont)
            .fontWeight(.medium)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(DraftLine.spoken(isAuto: isAuto, names: session.recipientSummary))
            .accessibilityIdentifier("composer.draftLine")
            Spacer(minLength: theme.space3)
            IconButton(symbol: "macwindow.on.rectangle", help: "Pop out", size: ComposerMetrics.lineBand,
                       shortcut: .popOutComposer, tipTitle: "Pop out") {
                manager.perform(.popOutComposer, in: session)
            }
        }
        .frame(height: ComposerMetrics.lineBand)
        .padding(.bottom, theme.space3)
    }

    public static func drawsQuickReplies(_ session: ComposeSession, manager: ComposeManager) -> Bool {
        if case .docked = session.placement { return false }
        guard session.aiPanel == nil, let strip = manager.instantReply(for: session) else { return false }
        return strip.showsRow
    }

    private var isAutoDraft: Bool {
        session.isAutoDraft || manager.instantReply(for: session)?.insertedUntouched == true
    }

    private var titleRow: some View {
        HStack(spacing: theme.space3) {
            Text(session.title)
                .font(theme.typeSubject.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: theme.space5)
            if session.placement != .window {
                IconButton(symbol: "macwindow.on.rectangle", help: "Pop out", shortcut: .popOutComposer, tipTitle: "Pop out") {
                    manager.perform(.popOutComposer, in: session)
                }
            }
            IconButton(symbol: "xmark", help: "Close and keep the draft", shortcut: .closeComposer,
                       tipTitle: "Close and keep the draft", action: onClose)
        }
        .padding(.bottom, theme.space4)
    }

    private var fieldButtons: some View {
        HStack(spacing: theme.space1) {
            if isDocked, !session.showsSubject {
                TextButton(title: "Subject", help: "Edit the subject", compact: true) { session.showsSubject = true }
            }
            if !session.showsCc {
                TextButton(title: "Cc", help: "Add Cc", compact: true, shortcut: .showCc) { session.showCc() }
            }
            if !session.showsBcc {
                TextButton(title: "Bcc", help: "Add Bcc", compact: true, shortcut: .showBcc) { session.showBcc() }
            }
        }
    }

    private var subjectRow: some View {
        HStack(alignment: .center, spacing: 0) {
            FieldLabel(title: "Subject")
            TextField("", text: Binding(get: { session.subject }, set: { session.subject = $0 }))
                .textFieldStyle(.plain)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .autocorrectionDisabled(!manager.textSettings.flags(for: session.account).autocorrect)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: ComposerMetrics.lineBand)
                .accessibilityLabel("Subject")
        }
        .padding(.vertical, (rowHeight - ComposerMetrics.lineBand) / 2)
        .frame(minHeight: rowHeight)
    }
}

public enum ComposerMetrics {
    static let labelWidth: CGFloat = 56
    static let fieldHeight: CGFloat = 36
    static let dockedFieldHeight: CGFloat = 32
    static let lineBand: CGFloat = 22
    static let iconButton: CGFloat = 28
    static let compactBannerHeight: CGFloat = 24
    static let snippetPopoverWidth: CGFloat = 520
    static let snippetRowHeight: CGFloat = 36
    static let snippetNameWidth: CGFloat = 160
    static let suggestionsWidth: CGFloat = 360
    static let suggestionRowHeight: CGFloat = 40
    static let bannerHeight: CGFloat = 32
    public static let editorMinDocked: CGFloat = 96
    public static let editorMinModal: CGFloat = 240
    public static let dockedMaxFraction: CGFloat = 0.6
}

struct FieldLabel: View {
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(title)
            .font(theme.typeBody.swiftUIFont)
            .foregroundStyle(theme.textSecondary.color)
            .lineLimit(1)
            .frame(width: ComposerMetrics.labelWidth, height: ComposerMetrics.lineBand, alignment: .leading)
            .accessibilityHidden(true)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: ThemeColor?
    var size: CGFloat = ComposerMetrics.iconButton
    var shortcut: ActionID?
    var tipTitle: String?
    var tipHint: String?
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size < ComposerMetrics.iconButton ? 12 : 14))
                .foregroundStyle((tint ?? theme.textSecondary).color)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shortcutTip(shortcut, title: tipTitle, hint: tipHint, orHelp: help)
        .accessibilityLabel(help.components(separatedBy: "  ").first ?? help)
    }
}

struct TextButton: View {
    let title: String
    let help: String
    var strong = false
    var enabled = true
    var compact = false
    var shortcut: ActionID?
    var tipTitle: String?
    var tipHint: String?
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(strong ? theme.typeBodyStrong.swiftUIFont : theme.typeBody.swiftUIFont)
                .foregroundStyle((enabled ? (strong ? theme.textPrimary : theme.textSecondary) : theme.textDisabled).color)
                .padding(.vertical, compact ? 0 : 6)
                .padding(.horizontal, compact ? 6 : 10)
                .frame(minHeight: compact ? ComposerMetrics.lineBand : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .modifier(TextButtonHelp(help: help, shortcut: shortcut, tipTitle: tipTitle, tipHint: tipHint))
    }
}

private struct TextButtonHelp: ViewModifier {
    let help: String
    let shortcut: ActionID?
    let tipTitle: String?
    let tipHint: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let shortcut {
            content.shortcutTip(shortcut, title: tipTitle, hint: tipHint)
        } else {
            content.help(help).accessibilityHint(help)
        }
    }
}

public struct ComposerReveal: @unchecked Sendable {
    public static let space = "composer.card"
    public static let panelID = "composer.ai.panel"
    public let action: @MainActor (CGRect) -> Void

    public init(action: @escaping @MainActor (CGRect) -> Void) {
        self.action = action
    }
}

extension EnvironmentValues {
    @Entry public var composerReveal: ComposerReveal? = nil
}

struct ComposerPanelFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

enum DraftLine {
    static func parts(isAuto: Bool, names: String?) -> (lead: String, rest: String?) {
        (isAuto ? String(localized: "Auto Draft") : String(localized: "Draft"), names.map { String(localized: "to \($0)") })
    }

    static func spoken(isAuto: Bool, names: String?) -> String {
        guard let names else { return isAuto ? String(localized: "Auto Draft") : String(localized: "Draft") }
        return isAuto ? String(localized: "Auto Draft to \(names)") : String(localized: "Draft to \(names)")
    }
}
