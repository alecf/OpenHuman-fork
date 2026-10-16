import MailActions
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import UniformTypeIdentifiers

struct FromLine: View {
    let session: ComposeSession
    let manager: ComposeManager
    var rowHeight: CGFloat = ComposerMetrics.fieldHeight
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            FieldLabel(title: "From")
            HStack(alignment: .center, spacing: theme.space3) {
                address
                    .layoutPriority(1)
                if session.from.needsVerification {
                    Label("Not verified in Gmail", systemImage: "exclamationmark.triangle")
                        .font(theme.typeCaption.swiftUIFont)
                        .foregroundStyle(theme.textWarning.color)
                        .lineLimit(1)
                }
                if session.showsFromReason {
                    Text(reasonLine)
                        .font(theme.typeCaption.swiftUIFont)
                        .foregroundStyle(theme.textWarning.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityLabel(reasonLine)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: ComposerMetrics.lineBand)
        .padding(.vertical, (rowHeight - ComposerMetrics.lineBand) / 2)
        .help(session.showsFromReason ? "" : reasonLine)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("From \(session.from.display). \(reasonLine)")
    }

    @ViewBuilder
    private var address: some View {
        let text = Text(session.from.display)
            .font(theme.typeBody.swiftUIFont)
            .foregroundStyle(theme.textPrimary.color)
            .lineLimit(1)
            .truncationMode(.middle)
        if session.offersFromPicker {
            Button {
                session.isFromPickerOpen.toggle()
            } label: {
                HStack(spacing: theme.space2) {
                    text
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary.color)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shortcutTip(.chooseFrom, title: "Change the From address", alignment: .leading)
            .popover(isPresented: Binding(get: { session.isFromPickerOpen }, set: { session.isFromPickerOpen = $0 }),
                     arrowEdge: .bottom) {
                FromPicker(session: session)
            }
        } else {
            text
        }
    }

    private var reasonLine: String {
        var parts = [session.fromReason.text]
        if session.isFromNonDefault { parts.append(String(localized: "not your default address")) }
        return parts.joined(separator: " · ")
    }
}

struct FromPicker: View {
    let session: ComposeSession
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(session.fromChoices) { identity in
                Button { session.chooseFrom(identity) } label: {
                    HStack(spacing: theme.space3) {
                        Image(systemName: identity == session.from ? "checkmark" : "")
                            .frame(width: 14)
                            .foregroundStyle(theme.accentText.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(identity.display)
                                .font(theme.typeBody.swiftUIFont)
                                .foregroundStyle(theme.textPrimary.color)
                            if identity.isGmailDefault || identity.needsVerification {
                                Text(identity.needsVerification ? "Not verified in Gmail: sending may fail"
                                                                : "Gmail default")
                                    .font(theme.typeCaption.swiftUIFont)
                                    .foregroundStyle((identity.needsVerification ? theme.textWarning : theme.textTertiary).color)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, theme.space4)
                    .frame(minHeight: ComposerMetrics.suggestionRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(identity.display)
                .accessibilityAddTraits(identity == session.from ? .isSelected : [])
            }
        }
        .padding(.vertical, theme.space2)
        .frame(minWidth: ComposerMetrics.suggestionsWidth)
    }
}

struct RecipientRow<Trailing: View>: View {
    let field: RecipientFieldModel
    let session: ComposeSession
    var rowHeight: CGFloat = ComposerMetrics.fieldHeight
    var inlinePopovers = false
    var recentMailLookup: (@Sendable (String) async -> ThreadRow?)? = nil
    var historyLookup: (@Sendable (String) async -> Int?)? = nil
    var openConversations: ((EmailAddress) -> Void)? = nil
    let autofocus: Bool
    @ViewBuilder let trailing: Trailing
    @Environment(\.theme) private var theme
    @Environment(\.undoManager) private var undoManager
    @FocusState private var focused: Bool
    @State private var recentMail = RecentMailDetails()
    @State private var history = RecipientHistory()
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                FieldLabel(title: field.title)
                TokenFlowLayout(spacing: 4) {
                    ForEach(field.tokens, id: \.self) { address in
                        RecipientToken(address: address, expanded: session.linkRecipients?.contains(address) == true,
                                       moves: moves(for: address),
                                       dragged: session.recipientDrag == RecipientDrag(address: address, from: field.kind)) {
                            field.remove(address)
                        }
                        .onDrag {
                            session.beginRecipientDrag(address, from: field.kind)
                            return NSItemProvider(object: RecipientMove.dragText(address) as NSString)
                        }
                    }
                    if field.tokens.isEmpty, isDropZone {
                        Text("Drop here")
                            .font(theme.typeBody.swiftUIFont)
                            .foregroundStyle(theme.textTertiary.color)
                            .frame(height: ComposerMetrics.lineBand)
                            .accessibilityHidden(true)
                    }
                    TextField("", text: Binding(get: { field.text }, set: { field.text = $0 }))
                        .textFieldStyle(.plain)
                        .font(theme.typeBody.swiftUIFont)
                        .foregroundStyle(theme.textPrimary.color)
                        .autocorrectionDisabled(true)
                        // Why: SwiftUI sized the AppKit field to its line or to the whole band between passes, jittering the text
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 120, minHeight: ComposerMetrics.lineBand, maxHeight: ComposerMetrics.lineBand)
                        .focused($focused)
                        .onSubmit { field.commit() }
                        .onKeyPress(.downArrow) { field.suggestions.isEmpty ? .ignored : (field.moveSuggestion(by: 1), .handled).1 }
                        .onKeyPress(.upArrow) { field.suggestions.isEmpty ? .ignored : (field.moveSuggestion(by: -1), .handled).1 }
                        .onKeyPress(.tab) { field.suggestions.isEmpty ? .ignored : (field.commit(), .handled).1 }
                        .onKeyPress(.delete) { field.text.isEmpty && !field.tokens.isEmpty ? (field.removeLast(), .handled).1 : .ignored }
                        .onChange(of: focused) { _, isFocused in if !isFocused { field.commitText() } }
                        .accessibilityLabel(field.title)
                }
                trailing.frame(height: ComposerMetrics.lineBand)
            }
            .padding(.vertical, (rowHeight - ComposerMetrics.lineBand) / 2)
            .background {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgRowSelected.color)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(of: [.plainText], delegate: RecipientDropTarget(session: session, kind: field.kind,
                                                                    undoManager: undoManager, targeted: $dropTargeted))
            .onDragSessionUpdated { drag in
                switch drag.phase {
                case .ended, .dataTransferCompleted: session.endRecipientDrag()
                default: break
                }
            }
            historyLine
            if inlinePopovers, focused, !field.suggestions.isEmpty {
                SuggestionList(field: field, detail: recentMailDetail)
                    .padding(.leading, ComposerMetrics.labelWidth)
                    .padding(.bottom, theme.space3)
            }
        }
        .frame(minHeight: rowHeight)
        .overlay(alignment: .bottomLeading) {
            if !inlinePopovers, focused, !field.suggestions.isEmpty {
                SuggestionList(field: field, detail: recentMailDetail)
                    .offset(x: ComposerMetrics.labelWidth, y: CGFloat(field.suggestions.count) * ComposerMetrics.suggestionRowHeight + 8)
                    .zIndex(10)
            }
        }
        .onChange(of: highlightedSuggestion) { _, email in
            guard let recentMailLookup else { return }
            recentMail.lookup = recentMailLookup
            recentMail.highlight(focused ? email : nil)
        }
        .zIndex(focused ? 5 : 0)
        .onAppear {
            if autofocus || field.focusRequest != field.focusHandled { focused = true }
            field.focusHandled = field.focusRequest
            loadHistory()
        }
        .onChange(of: field.tokens) { _, _ in loadHistory() }
        .onChange(of: field.focusRequest) { _, request in
            field.focusHandled = request
            focused = true
        }
    }

    @ViewBuilder
    private var historyLine: some View {
        if historyLookup != nil, let openConversations, let address = history.shown(in: field.tokens),
           let line = history.line(for: address) {
            Button(line) { openConversations(address) }
                .ohLinkButtonStyle()
                .font(theme.typeCaption.swiftUIFont)
                .lineLimit(1)
                .help("Search every conversation with \(address.email)")
                .frame(height: theme.typeCaption.lineHeight, alignment: .leading)
                .padding(.leading, ComposerMetrics.labelWidth)
                .padding(.bottom, theme.space2)
                .accessibilityIdentifier("compose.recipientHistory")
        } else if historyLookup != nil, history.isPending(in: field.tokens) {
            Color.clear
                .frame(height: theme.typeCaption.lineHeight)
                .padding(.bottom, theme.space2)
                .accessibilityHidden(true)
        }
    }

    private func loadHistory() {
        guard field.kind == .to, let historyLookup else { return }
        history.lookup = historyLookup
        for token in field.tokens { history.load(token.email) }
    }

    private var highlightedSuggestion: String? {
        field.suggestions.indices.contains(field.suggestionCursor) ? field.suggestions[field.suggestionCursor].email : nil
    }

    private var isDropZone: Bool {
        guard let drag = session.recipientDrag else { return false }
        return drag.from != field.kind
    }

    private func moves(for address: EmailAddress) -> [RecipientTokenMove] {
        let source = field.kind
        return session.moveTargets(from: source).map { target in
            RecipientTokenMove(title: RecipientMove.title(movingTo: target)) {
                _ = session.moveRecipient(address, from: source, to: target, undoManager: undoManager)
            }
        }
    }

    private var recentMailDetail: ((EmailAddress) -> String?)? {
        guard recentMailLookup != nil else { return nil }
        return { address in recentMail.detail(for: address.email) }
    }
}

struct RecipientTokenMove {
    let title: String
    let action: () -> Void
}

struct RecipientDropTarget: DropDelegate {
    let session: ComposeSession
    let kind: RecipientFieldModel.Kind
    let undoManager: UndoManager?
    let targeted: Binding<Bool>

    private var accepts: Bool {
        guard let drag = session.recipientDrag else { return false }
        return drag.from != kind
    }

    func validateDrop(info: DropInfo) -> Bool {
        session.recipientDrag != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        targeted.wrappedValue = accepts
    }

    func dropExited(info: DropInfo) {
        targeted.wrappedValue = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: accepts ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted.wrappedValue = false
        guard accepts else {
            session.endRecipientDrag()
            return false
        }
        return session.dropRecipient(on: kind, undoManager: undoManager)
    }
}

struct RecipientToken: View {
    let address: EmailAddress
    let expanded: Bool
    var moves: [RecipientTokenMove] = []
    var dragged = false
    let remove: () -> Void
    @Environment(\.theme) private var theme
    @State private var removeHovered = false

    static let removeHitWidth: CGFloat = 20
    static let removeGlyphSize: CGFloat = 9

    struct RemoveStyle: Equatable {
        let opacity: Double
        let emphasized: Bool
    }

    static func removeStyle(hovered: Bool) -> RemoveStyle {
        RemoveStyle(opacity: 1, emphasized: hovered)
    }

    var body: some View {
        let token = theme.component.token
        let valid = RecipientParser.isValid(address.email)
        let style = Self.removeStyle(hovered: removeHovered)
        HStack(spacing: 0) {
            Text(label)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle((valid ? theme.textPrimary : theme.textDanger).color)
                .underline(!valid, pattern: .dot, color: theme.textDanger.color)
                .lineLimit(1)
                .padding(.leading, 8)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: Self.removeGlyphSize, weight: .semibold))
                    .foregroundStyle((style.emphasized ? theme.textPrimary : theme.textSecondary).color)
                    .frame(width: Self.removeHitWidth, height: token.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(style.opacity)
            .onHover { removeHovered = $0 }
            .help("Remove \(address.email)")
            .accessibilityHidden(true)
        }
        .padding(.trailing, 2)
        .frame(height: token.height)
        .background(RoundedRectangle(cornerRadius: token.radius).fill((dragged ? token.bgSelected : token.bg).color))
        .opacity(dragged ? 0.6 : 1)
        .help(valid ? address.email : "Not a valid address")
        .contextMenu {
            ForEach(Array(moves.enumerated()), id: \.offset) { _, move in
                Button(move.title, action: move.action)
            }
            Button("Remove", action: remove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(valid ? label : "\(label), not a valid address")
        .accessibilityAction(named: Text("Remove \(label)"), remove)
        .accessibilityActions {
            ForEach(Array(moves.enumerated()), id: \.offset) { _, move in
                Button(move.title, action: move.action)
            }
        }
    }

    private var label: String {
        if expanded, let name = address.name, !name.isEmpty { return "\(name) <\(address.email)>" }
        if expanded { return address.email }
        return RecipientParser.displayName(address)
    }
}

struct SuggestionList: View {
    let field: RecipientFieldModel
    var detail: ((EmailAddress) -> String?)? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(field.suggestions.enumerated()), id: \.offset) { index, address in
                let last = index == field.suggestionCursor ? detail?(address) : nil
                Button { field.accept(address) } label: {
                    HStack(spacing: theme.space3) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(RecipientParser.displayName(address))
                                .font(theme.typeBody.swiftUIFont)
                                .foregroundStyle(theme.textPrimary.color)
                            if address.name != nil {
                                Text(address.email)
                                    .font(theme.typeMeta.swiftUIFont)
                                    .foregroundStyle(theme.textSecondary.color)
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        if let last {
                            Text(last)
                                .font(theme.typeMeta.swiftUIFont)
                                .monospacedDigit()
                                .foregroundStyle(theme.textTertiary.color)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, theme.space4)
                    .frame(width: ComposerMetrics.suggestionsWidth, height: ComposerMetrics.suggestionRowHeight, alignment: .leading)
                    .background(index == field.suggestionCursor ? theme.bgRowSelected.color : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(RecipientParser.displayName(address))
                .accessibilityValue(last ?? "")
            }
        }
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgElevated.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusLG).strokeBorder(theme.borderElevated.color, lineWidth: theme.borderWidthHairline))
        .themeShadow(theme.shadow2)
    }
}

struct TokenFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let w = min(size.width, width)
            if x > 0, x + w > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += w + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            let isLast = index == subviews.count - 1
            if x > bounds.minX, x + min(size.width, bounds.width) > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            if isLast { size.width = max(size.width, bounds.maxX - x) }
            size.width = min(size.width, bounds.maxX - x)
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct ComposerBanners: View {
    let session: ComposeSession
    let manager: ComposeManager
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            if case .localOnly(let why) = session.saveState {
                CompactBanner(symbol: "lock", text: shortLocalOnlyText(why), help: localOnlyText(why))
            }
            if let link = session.linkBanner {
                Banner(symbol: "exclamationmark.triangle", text: link)
                if session.linkTriedBcc {
                    Text("This link tried to add a Bcc recipient; it was ignored.")
                        .font(theme.typeCaption.swiftUIFont)
                        .foregroundStyle(theme.textTertiary.color)
                }
            }
            if session.draftStatus == .failed, let error = session.draftError {
                HStack(spacing: theme.space3) {
                    Banner(symbol: "exclamationmark.triangle", text: String(localized: "Not sent: \(error)."))
                    TextButton(title: "Send now", help: "Send it now", strong: true, shortcut: .send, tipTitle: "Send it now") {
                        manager.perform(.send, in: session)
                    }
                    TextButton(title: "Reschedule", help: "Pick a new time", shortcut: .sendLater, tipTitle: "Pick a new time") {
                        manager.perform(.sendLater, in: session)
                    }
                }
            } else if let sendAt = session.sendAt {
                HStack(spacing: theme.space3) {
                    Label(String(localized: "Sends at \(manager.formatSendAt(sendAt))"), systemImage: "paperplane")
                        .font(theme.typeBody.swiftUIFont)
                        .foregroundStyle(theme.accentText.color)
                    TextButton(title: "Cancel", help: "Cancel send later", shortcut: .cancelSendLater) {
                        manager.perform(.cancelSendLater, in: session)
                    }
                    TextButton(title: "Reschedule", help: "Pick a new time", shortcut: .sendLater, tipTitle: "Pick a new time") {
                        manager.perform(.sendLater, in: session)
                    }
                }
            }
            if session.source != .user, session.review == .pending {
                Banner(symbol: "sparkles", text: String(localized: "An agent wrote this draft. Review it before sending or scheduling."))
            }
        }
        .padding(.bottom, hasContent ? theme.space3 : 0)
    }

    private var hasContent: Bool {
        if case .localOnly = session.saveState { return true }
        return session.linkBanner != nil || session.sendAt != nil || session.draftStatus == .failed
            || (session.source != .user && session.review == .pending)
    }

    private func localOnlyText(_ why: String) -> String {
        manager.canSendInThisProcess
            ? why
            : String(localized: "\(why). Sending is off: Send is refused and nothing is queued.")
    }

    private func shortLocalOnlyText(_ why: String) -> String {
        manager.canSendInThisProcess ? why : String(localized: "\(why) · Sending is off")
    }
}

struct CompactBanner: View {
    let symbol: String
    let text: String
    let help: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space2 + 2) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            Text(text)
                .font(theme.typeMeta.swiftUIFont)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.textSecondary.color)
        .padding(.horizontal, theme.space3)
        .frame(height: ComposerMetrics.compactBannerHeight)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }
}

struct Banner: View {
    let symbol: String
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space3) {
            Image(systemName: symbol).font(.system(size: 14))
            Text(text).font(theme.typeBody.swiftUIFont).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.textWarning.color)
        .padding(.horizontal, theme.space4)
        .frame(minHeight: ComposerMetrics.bannerHeight)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgWarningSubtle.color))
        .accessibilityElement(children: .combine)
    }
}

struct SignatureAndQuote: View {
    let session: ComposeSession
    var inline = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            if let preview = session.signaturePreview {
                HStack(alignment: .top, spacing: theme.space3) {
                    Text(session.includesSignature ? preview : String(localized: "Signature removed for this message"))
                        .font(theme.typeMeta.swiftUIFont)
                        .foregroundStyle((session.includesSignature ? theme.textSecondary : theme.textTertiary).color)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    TextButton(title: session.includesSignature ? "Remove signature" : "Add signature",
                               help: "The signature of the From address", compact: true) {
                        session.includesSignature.toggle()
                    }
                }
            }
            if !session.quotedHTML.isEmpty {
                VStack(alignment: .leading, spacing: theme.space2) {
                    Button {
                        session.isQuoteExpanded.toggle()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.textSecondary.color)
                            .frame(width: 24, height: 16)
                            .background(Capsule().fill(theme.bgSunken.color))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(session.isQuoteExpanded ? "Hide the quoted message" : "Show the quoted message")
                    .accessibilityLabel(session.isQuoteExpanded ? "Hide the quoted message" : "Show the quoted message")
                    .accessibilityIdentifier("composer.quoteToggle")
                    if session.isQuoteExpanded {
                        if inline {
                            quote
                        } else {
                            ScrollView { quote }.frame(maxHeight: 240)
                        }
                    }
                }
            }
        }
        .padding(.bottom, theme.space4)
    }

    private var quote: some View {
        let preview = QuotePreview(quotedText: session.quotedText, quotedHTML: session.quotedHTML)
        return VStack(alignment: .leading, spacing: theme.space2) {
            if !preview.header.isEmpty {
                Text(preview.header)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityIdentifier("composer.quoteAttribution")
            }
            if !preview.body.isEmpty {
                HStack(alignment: .top, spacing: theme.space4) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.borderControl.color)
                        .frame(width: 2)
                    Text(preview.body)
                        .font(theme.typeMeta.swiftUIFont)
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, theme.space1)
    }
}

struct AttachmentChips: View {
    let session: ComposeSession
    @Environment(\.theme) private var theme

    var body: some View {
        TokenFlowLayout(spacing: 6) {
            ForEach(session.fileAttachments, id: \.self) { attachment in
                HStack(spacing: 6) {
                    Image(systemName: "paperclip").font(.system(size: 11))
                    Text(attachment.filename).lineLimit(1).truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                        .foregroundStyle(theme.textTertiary.color)
                    Button { session.removeAttachment(attachment) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(attachment.filename)")
                }
                .font(theme.typeMeta.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .padding(.horizontal, 8)
                .frame(height: theme.component.token.height)
                .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
            }
            Text(ByteCountFormatter.string(fromByteCount: Int64(session.attachmentBytes), countStyle: .file) + " total")
                .font(theme.typeCaption.swiftUIFont)
                .foregroundStyle(theme.textTertiary.color)
        }
        .padding(.vertical, theme.space2)
    }
}

struct NoticeLine: View {
    let notice: ComposeSession.Notice
    var sendAgain: (() -> Void)? = nil
    let dismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space3) {
            Image(systemName: notice.kind == .info ? "info.circle" : "exclamationmark.triangle").font(.system(size: 13))
            Text(notice.text).font(theme.typeBody.swiftUIFont).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if notice.offersSendAgain, let sendAgain {
                TextButton(title: "Send again", help: "Send it again", strong: true, compact: true, shortcut: .send,
                           tipTitle: "Send it again", action: sendAgain)
                    .accessibilityIdentifier("composer.notice.sendAgain")
            }
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(color.color)
        .padding(.horizontal, theme.space4)
        .padding(.vertical, theme.space2)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD)
            .fill((notice.kind == .error ? theme.bgDangerSubtle : theme.bgWarningSubtle).color))
        .padding(.vertical, theme.space2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var color: ThemeColor {
        switch notice.kind {
        case .info: theme.textSecondary
        case .warning: theme.textWarning
        case .error: theme.textDanger
        }
    }
}

struct ComposerActionBar: View {
    let session: ComposeSession
    let manager: ComposeManager
    @Environment(\.theme) private var theme
    @State private var marksDone: StoredSetting<Bool>?

    private var showsMarkDone: Bool {
        (marksDone?.value ?? true) && manager.archivesOnSend(session)
    }

    var body: some View {
        HStack(spacing: theme.space2) {
            SendButton(enabled: manager.canSendInThisProcess, marksDone: showsMarkDone, tipHint: sendTipHint) {
                manager.perform(.send, in: session)
            }
            .padding(.trailing, theme.space1)
            .task {
                guard marksDone == nil else { return }
                let setting = manager.makeSendMarksDoneSetting()
                setting.start()
                marksDone = setting
            }
            if manager.offersSendLater {
                TextButton(title: "Send later", help: "Send later", enabled: manager.canSendInThisProcess,
                           shortcut: .sendLater, tipTitle: "Send later") {
                    manager.perform(.sendLater, in: session)
                }
            }
            if let remind = manager.remindButton(for: session) {
                TextButton(title: manager.remindTitle(session), help: remind.help, enabled: remind.isEnabled,
                           shortcut: .composeRemind, tipTitle: manager.remindTitle(session),
                           tipHint: remind.isEnabled ? nil : remind.help) {
                    manager.remind(from: session)
                }
                .accessibilityIdentifier("composer.remindMe")
                if session.pendingReminder != nil {
                    IconButton(symbol: "xmark", help: "Don't remind me", size: ComposerMetrics.lineBand) {
                        session.clearPendingReminder()
                    }
                    .accessibilityIdentifier("composer.remindMe.clear")
                }
            }
            TextButton(title: "Share draft", help: "Sharing a draft isn't available yet", enabled: false) {}
                .accessibilityIdentifier("composer.shareDraft")
            Spacer(minLength: theme.space4)
            if session.saveState.text != nil, !isLocalOnly {
                SaveStatusText(state: session.saveState)
                    .padding(.trailing, theme.space2)
            }
            if manager.aiCenter != nil {
                AIWordButton { manager.perform(.aiRewrite, in: session) }
            }
            if manager.calendarSidebar != nil {
                IconButton(symbol: "calendar", help: "Insert free times", shortcut: .calendarInsertAvailability) {
                    manager.perform(.calendarInsertAvailability, in: session)
                }
                .accessibilityIdentifier("composer.calendar")
            }
            IconButton(symbol: "curlybraces", help: "Snippets", shortcut: .insertSnippet, tipTitle: "Snippets") {
                manager.perform(.insertSnippet, in: session)
            }
            IconButton(symbol: session.isPlainText ? "text.alignleft" : "textformat",
                       help: session.isPlainText ? "Plain text: sends without formatting. Click for rich text"
                                                 : "Rich text. Click to send as plain text") {
                session.setPlainText(!session.isPlainText)
            }
            .accessibilityIdentifier("composer.plainText")
            .accessibilityValue(session.isPlainText ? "Plain text" : "Rich text")
            if manager.chooseFiles != nil {
                IconButton(symbol: "paperclip", help: "Attach", shortcut: .attachFiles, tipTitle: "Attach",
                           tipHint: String(localized: "(or drag ’n’ drop files)")) {
                    manager.perform(.attachFiles, in: session)
                }
            }
            IconButton(symbol: "trash", help: "Discard", shortcut: .discardDraft, tipTitle: "Discard") {
                manager.perform(.discardDraft, in: session)
            }
        }
        .frame(height: theme.component.compose.barHeight)
        .padding(.top, theme.space2)
    }

    private var isLocalOnly: Bool {
        if case .localOnly = session.saveState { true } else { false }
    }

    private var sendHelp: String {
        guard manager.canSendInThisProcess else { return String(localized: "Sending isn't available here") }
        let seconds = manager.undoSendSeconds
        return seconds > 0 ? String(localized: "Send  ⌘↵. Undo is there for \(seconds) s after sending.")
                           : String(localized: "Send  ⌘↵")
    }

    private var sendTipHint: String? {
        guard manager.canSendInThisProcess else { return sendHelp }
        let seconds = manager.undoSendSeconds
        return seconds > 0 ? String(localized: "Undo is there for \(seconds) s after sending.") : nil
    }
}

struct SaveStatusText: View {
    let state: ComposeSession.SaveState
    @Environment(\.theme) private var theme
    @State private var shown: String?
    @State private var savingSince: Date?

    var body: some View {
        HStack(spacing: theme.space3) {
            if let shown {
                Text(shown)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1)
            }
        }
        .task(id: state) { await follow(state) }
    }

    private func follow(_ state: ComposeSession.SaveState) async {
        if state == .saving {
            try? await Task.sleep(for: .milliseconds(Int(theme.motionSpinnerDelay)))
            guard !Task.isCancelled else { return }
            shown = state.text
            savingSince = Date()
            return
        }
        if let since = savingSince {
            let left = theme.motionSpinnerMinVisible / 1000 - Date().timeIntervalSince(since)
            if left > 0 {
                try? await Task.sleep(for: .milliseconds(Int(left * 1000)))
                guard !Task.isCancelled else { return }
            }
        }
        savingSince = nil
        shown = state.text
    }
}

struct SendButton: View {
    let enabled: Bool
    var marksDone = false
    var tipHint: String?
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space1) {
                Text("Send").font(theme.typeBodyStrong.swiftUIFont)
                    .foregroundStyle((enabled ? theme.textPrimary : theme.textDisabled).color)
                if marksDone {
                    Text(verbatim: "+").font(theme.typeCaption.swiftUIFont)
                        .foregroundStyle((enabled ? theme.textSecondary : theme.textDisabled).color)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                        .foregroundStyle((enabled ? theme.accentFill : theme.textDisabled).color)
                }
            }
            .padding(.horizontal, theme.space2)
            .frame(height: ComposerMetrics.iconButton)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shortcutTip(.send, title: marksDone ? String(localized: "Send and mark done") : String(localized: "Send"),
                     hint: tipHint)
        .accessibilityLabel(marksDone ? String(localized: "Send and mark done") : String(localized: "Send"))
        .accessibilityIdentifier("composer.send")
    }
}

struct AIWordButton: View {
    static let pencilSymbol = "pencil"
    static let sparkleSymbol = "sparkle"
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                Image(systemName: Self.pencilSymbol)
                    .font(.system(size: 14, weight: .regular))
                Image(systemName: Self.sparkleSymbol)
                    .font(.system(size: 7, weight: .semibold))
                    .offset(x: -4, y: -3)
            }
            .foregroundStyle(theme.textSecondary.color)
            .frame(width: ComposerMetrics.iconButton, height: ComposerMetrics.iconButton)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shortcutTip(.aiRewrite, title: "AI")
        .accessibilityLabel("AI")
        .accessibilityIdentifier("composer.ai")
    }
}

struct SnippetPickerView: View {
    let picker: SnippetPickerModel
    let showsSearchField: Bool
    @Environment(\.theme) private var theme
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSearchField {
                TextField("Search snippets", text: Binding(get: { picker.query }, set: { picker.query = $0 }))
                    .textFieldStyle(.plain)
                    .font(theme.typeBody.swiftUIFont)
                    .padding(.horizontal, theme.space4)
                    .frame(height: ComposerMetrics.snippetRowHeight)
                    .focused($searchFocused)
                    .onSubmit { picker.confirm() }
                    .overlayKeys(up: { picker.moveCursor(by: -1) }, down: { picker.moveCursor(by: 1) },
                                 escape: { picker.close() })
                Divider().overlay(theme.borderHairline.color)
            }
            if picker.isEmpty {
                Text(SnippetPickerModel.emptyText)
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(theme.space4)
            } else {
                ForEach(Array(picker.rows.enumerated()), id: \.element.id) { index, row in
                    Button { picker.choose(row.snippet) } label: {
                        HStack(spacing: theme.space4) {
                            Text(row.snippet.name)
                                .font(theme.typeBody.swiftUIFont)
                                .foregroundStyle(theme.textPrimary.color)
                                .lineLimit(1)
                                .frame(width: ComposerMetrics.snippetNameWidth, alignment: .leading)
                            Text(row.preview)
                                .font(theme.typeBody.swiftUIFont)
                                .foregroundStyle(theme.textSecondary.color)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let shortcut = row.snippet.shortcut { KeycapView(text: ";;" + shortcut) }
                        }
                        .padding(.horizontal, theme.space4)
                        .frame(height: ComposerMetrics.snippetRowHeight)
                        .background(CursorRowBackground(isCursor: index == picker.cursor))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.snippet.name)
                    .accessibilityValue(row.preview)
                }
            }
        }
        .frame(width: ComposerMetrics.snippetPopoverWidth)
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgElevated.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusLG).strokeBorder(theme.borderElevated.color, lineWidth: theme.borderWidthHairline))
        .themeShadow(theme.shadow2)
        .onAppear { if showsSearchField { searchFocused = true } }
    }
}

struct LinkConfirmationCard: View {
    let session: ComposeSession
    let manager: ComposeManager
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.bgScrim.color.onTapGesture { session.editLinkRecipients() }
            VStack(alignment: .leading, spacing: theme.space4) {
                Text("Send to these recipients?")
                    .font(theme.typeTitle.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                ForEach(session.linkRecipients ?? [], id: \.self) { address in
                    Text(address.name.map { "\($0) <\(address.email)>" } ?? address.email)
                        .font(theme.typeBody.swiftUIFont)
                        .foregroundStyle(theme.textPrimary.color)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Edit recipients") { session.editLinkRecipients() }
                        .keyboardShortcut(.cancelAction)
                    Button("Send") {
                        session.confirmLinkRecipients()
                        manager.perform(.send, in: session, source: .keyboard)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(theme.space6)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgElevated.color))
            .themeShadow(theme.shadow3)
        }
    }
}

struct SendConfirmationCard: View {
    let session: ComposeSession
    let manager: ComposeManager
    let card: ComposeSession.SendConfirmation
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.bgScrim.color.onTapGesture { session.cancelSendConfirmation() }
            VStack(alignment: .leading, spacing: theme.space4) {
                Text(card.title)
                    .font(theme.typeTitle.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .accessibilityAddTraits(.isHeader)
                Text(card.message)
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Don't ask again") { manager.confirmSend(in: session, stopAsking: true) }
                        .help("Turns off Settings › General › Confirm before sending")
                    Spacer()
                    Button("Cancel") { session.cancelSendConfirmation() }
                        .keyboardShortcut(.cancelAction)
                    Button(card.confirmTitle) { manager.confirmSend(in: session) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(theme.space6)
            .frame(maxWidth: 440)
            .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgElevated.color))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
                .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
            .themeShadow(theme.shadow3)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}
