import MailFeatures
import MailTheme
import SwiftUI

enum AskPanelMetrics {
    static let width: CGFloat = 640
    static let top: CGFloat = 96
    static let maxHeight: CGFloat = 560
    static let verticalMargin: CGFloat = 192
    static let answerMaxHeight: CGFloat = 240
    static let inputHeight: CGFloat = 52
    static let planLineHeight: CGFloat = 28
    static let groupHeight: CGFloat = 28
    static let rowHeight: CGFloat = 36
    static let exampleRowHeight: CGFloat = 32
    static let footerHeight: CGFloat = 32
    static let chipHeight: CGFloat = 22
    static let chipMaxWidth: CGFloat = 220
    static let rowsMaxHeight: CGFloat = 7 * rowHeight + 2 * groupHeight
}

public struct AskPanelView: View {
    @Bindable var model: AskModel
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @FocusState private var focused: Bool
    @State private var showsSearchingLine = false

    public init(model: AskModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { proxy in
            let maxHeight = min(AskPanelMetrics.maxHeight, max(proxy.size.height - AskPanelMetrics.verticalMargin, 240))
            ZStack(alignment: .top) {
                theme.bgScrim.color
                    .contentShape(Rectangle())
                    .onTapGesture { model.close() }
                    .accessibilityHidden(true)
                card(maxHeight: maxHeight)
                    .frame(width: min(AskPanelMetrics.width, max(proxy.size.width - OverlayMetrics.windowMargin, 280)))
                    .padding(.top, AskPanelMetrics.top)
            }
        }
        .transaction { $0.disablesAnimations = true }
        .task(id: model.phase) {
            showsSearchingLine = false
            guard model.phase == .retrieving else { return }
            try? await Task.sleep(for: .milliseconds(150))
            showsSearchingLine = !Task.isCancelled && model.phase == .retrieving
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .done, let text = model.readyAnnouncement { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private var divider: Color { (contrast == .increased ? theme.borderControl : theme.borderHairline).color }

    private func card(maxHeight: CGFloat) -> some View {
        let rowsHeight = rowsListHeight
        let chrome = AskPanelMetrics.inputHeight + AskPanelMetrics.planLineHeight + AskPanelMetrics.footerHeight + 48
        let answerMax = max(80, min(AskPanelMetrics.answerMaxHeight, maxHeight - chrome - rowsHeight))
        return VStack(alignment: .leading, spacing: 0) {
            input
            Divider().overlay(divider)
            planArea
            content(answerMax: answerMax)
            if !model.rows.isEmpty {
                Divider().overlay(divider)
                rowsList(height: rowsHeight)
            }
            Divider().overlay(divider)
            footer
        }
        .frame(maxHeight: maxHeight, alignment: .top)
        .background(RoundedRectangle(cornerRadius: theme.radiusXL).fill(theme.bgElevated.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusXL).strokeBorder(theme.textAI.color, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusXL))
        .themeShadow(theme.shadow3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AskWording.title)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            focused = true
            #if canImport(AppKit)
            if model.aiCenter?.pasteboard == nil { model.aiCenter?.pasteboard = AISystemPasteboard() }
            #endif
        }
    }

    private var input: some View {
        HStack(spacing: theme.space4) {
            Image(systemName: "sparkle")
                .font(.system(size: OverlayMetrics.rowIconSize))
                .foregroundStyle(theme.textAI.color)
                .accessibilityHidden(true)
            TextField(AskWording.title, text: $model.question,
                      prompt: Text(AskWording.placeholder).foregroundStyle(theme.textTertiary.color))
                .textFieldStyle(.plain)
                .font(theme.typePaletteInput.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .overlayInputLine(theme.typePaletteInput)
                .focused($focused)
                .onSubmit { model.submit() }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        model.showAsList()
                        return .handled
                    }
                    if press.modifiers.contains(.option) {
                        model.ask(followUp: false)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.tab, phases: .down) { press in
                    model.cycleScope(by: press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.upArrow) { model.moveUp() ? .handled : .ignored }
                .onKeyPress(.downArrow) { model.moveDown() ? .handled : .ignored }
                .onKeyPress(.escape) {
                    model.escape()
                    return .handled
                }
                .onKeyPress(KeyEquivalent("j"), phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.close()
                    return .handled
                }
                .onKeyPress(KeyEquivalent("c"), phases: .down) { press in
                    guard press.modifiers.contains(.command), model.canCopyAnswer else { return .ignored }
                    model.copyAnswer()
                    return .handled
                }
                .accessibilityLabel(AskWording.placeholder)
            if !model.scopes.isEmpty { scopeChip }
            KeycapView(text: "esc")
        }
        .padding(.horizontal, OverlayMetrics.rowIconX)
        .frame(height: AskPanelMetrics.inputHeight)
        .layoutPriority(1)
    }

    private var scopeChip: some View {
        Menu {
            ForEach(model.scopes, id: \.self) { scope in
                Button(model.title(of: scope)) { model.select(scope) }
            }
        } label: {
            Text(verbatim: model.scopeTitle)
                .font(theme.typeCaption.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, theme.space3)
                .frame(maxWidth: AskPanelMetrics.chipMaxWidth)
                .frame(height: AskPanelMetrics.chipHeight)
                .background(Capsule().fill(theme.bgSunken.color))
        }
        .ohBorderlessMenuStyle()
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "Scope: \(model.scopeTitle)"))
        .accessibilityHint(String(localized: "Tab changes it"))
    }

    @ViewBuilder
    private var planArea: some View {
        let text = planText
        if !text.isEmpty || model.isWorking {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: text)
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, OverlayMetrics.rowIconX)
                    .frame(maxWidth: .infinity, minHeight: AskPanelMetrics.planLineHeight, alignment: .leading)
                if model.isWorking { progress }
            }
        }
    }

    private var planText: String {
        if let line = model.planLine, model.phase != .planning { return line }
        switch model.phase {
        case .planning: return AskWording.planning
        case .retrieving: return showsSearchingLine ? AskWording.searching : ""
        default: return ""
        }
    }

    @ViewBuilder
    private var progress: some View {
        if reduceMotion {
            VStack(alignment: .leading, spacing: theme.space1) {
                GeometryReader { proxy in
                    Capsule().fill(theme.textAI.color).frame(width: proxy.size.width * 0.3, height: 2)
                }
                .frame(height: 2)
                Text(AskWording.working)
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .padding(.horizontal, OverlayMetrics.rowIconX)
            }
            .accessibilityElement(children: .combine)
        } else {
            AIProgressLine()
        }
    }

    private func content(answerMax: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            if let asked = model.askedAtText { caption(asked) }
            if model.isSuspicious { suspiciousStrip }
            if !model.answer.isEmpty { answer(maxHeight: answerMax) }
            if model.isTruncated { caption(AskWording.truncated) }
            if model.phase == .stopped { caption(AskWording.stopped) }
            if let status = model.statusText { statusLine(status) }
            if let consent = model.consent {
                AIConsentView(request: consent, center: model.aiCenter,
                              accept: { Task { await model.acceptConsent() } }, decline: { model.declineConsent() })
            }
            if showsExamples { examples }
        }
        .padding(.horizontal, OverlayMetrics.rowIconX)
        .padding(.vertical, hasContent ? theme.space3 : 0)
    }

    private var hasContent: Bool {
        model.askedAtText != nil || model.isSuspicious || !model.answer.isEmpty || model.statusText != nil
            || model.consent != nil || model.phase == .stopped || showsExamples
    }

    private var showsExamples: Bool {
        model.phase == .idle && model.answer.isEmpty && model.question.isEmpty && model.statusText == nil
    }

    private func answer(maxHeight: CGFloat) -> some View {
        ScrollView {
            Text(verbatim: model.answer)
                .font(theme.typeReader.swiftUIFont)
                .foregroundStyle(answerColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(String(localized: "Answer"))
        .accessibilityValue(model.answer)
    }

    private var answerColor: Color {
        if model.phase == .stopped { return theme.textTertiary.color }
        if model.phase == .done, model.sources.isEmpty { return theme.textSecondary.color }
        return theme.textPrimary.color
    }

    private var suspiciousStrip: some View {
        Label {
            Text(AskWording.suspicious)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundStyle(theme.textWarning.color)
        }
        .padding(.vertical, theme.space3)
        .padding(.horizontal, theme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgWarningSubtle.color))
        .accessibilityElement(children: .combine)
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(theme.typeCaption.swiftUIFont)
            .foregroundStyle(theme.textTertiary.color)
    }

    private func statusLine(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            Text(verbatim: text)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle((statusIsError ? theme.textDanger : theme.textSecondary).color)
                .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            if model.phase == .failed(.aiOff) {
                Button(AskWording.openSettings) {
                    model.close()
                    openSettings()
                }
                .ohLinkButtonStyle()
                .font(theme.typeBody.swiftUIFont)
            }
            #endif
        }
    }

    private var statusIsError: Bool {
        guard case .failed(let failure) = model.phase else { return false }
        switch failure {
        case .aiOff, .unavailable, .onDeviceOnly, .needsConsent: return false
        default: return true
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AskWording.examples, id: \.self) { example in
                Button {
                    model.question = example
                    model.ask(followUp: false)
                } label: {
                    Text(verbatim: example)
                        .font(theme.typeBody.swiftUIFont)
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(maxWidth: .infinity, minHeight: AskPanelMetrics.exampleRowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private enum Item: Identifiable {
        case header(String)
        case row(Int, AskModel.Row)

        var id: String {
            switch self {
            case .header(let title): "header.\(title)"
            case .row(_, let row): row.id
            }
        }
    }

    private var items: [Item] {
        var out: [Item] = []
        var group = ""
        for (index, row) in model.rows.enumerated() {
            let title: String
            switch row {
            case .source: title = AskWording.sources
            case .otherMatch, .showMore: title = AskWording.alsoMatched
            case .olderMail: title = ""
            }
            if title != group {
                if !title.isEmpty { out.append(.header(title)) }
                group = title
            }
            out.append(.row(index, row))
        }
        return out
    }

    private var rowsListHeight: CGFloat {
        let headers = items.filter { if case .header = $0 { true } else { false } }.count
        let content = CGFloat(model.rows.count) * AskPanelMetrics.rowHeight + CGFloat(headers) * AskPanelMetrics.groupHeight
            + theme.space2 * 2
        return min(content, AskPanelMetrics.rowsMaxHeight)
    }

    private func rowsList(height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case .header(let title):
                            OverlayGroupHeader(title: title, height: AskPanelMetrics.groupHeight)
                        case .row(let index, let row):
                            rowView(row, index: index).id(row.id)
                        }
                    }
                }
                .padding(.vertical, theme.space2)
            }
            .frame(height: height)
            .onChange(of: model.cursor) { _, cursor in
                if let cursor, model.rows.indices.contains(cursor) { proxy.scrollTo(model.rows[cursor].id) }
            }
        }
    }

    private func rowView(_ row: AskModel.Row, index: Int) -> some View {
        let isCursor = model.cursor == index
        let enabled = row != .olderMail || model.olderMailEnabled
        return Button {
            model.moveCursor(to: index)
            model.activate(row)
        } label: {
            HStack(spacing: 0) {
                switch row {
                case .source(let source), .otherMatch(let source):
                    sourceLabel(source)
                case .showMore(let count):
                    plainRow(AskWording.showMore(count), symbol: "chevron.down", color: theme.accentText)
                case .olderMail:
                    plainRow(model.olderMailText ?? "", symbol: "magnifyingglass",
                             color: enabled ? theme.accentText : theme.textDisabled)
                }
            }
            .padding(.trailing, OverlayMetrics.rowIconX)
            .frame(height: AskPanelMetrics.rowHeight)
            .background(CursorRowBackground(isCursor: isCursor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(model.spokenLabel(row))
        .accessibilityAddTraits(isCursor ? .isSelected : [])
    }

    private func sourceLabel(_ source: AskSource) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "envelope")
                .font(.system(size: OverlayMetrics.rowIconSize))
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: OverlayMetrics.rowLabelX - OverlayMetrics.rowIconX, alignment: .leading)
                .padding(.leading, OverlayMetrics.rowIconX)
            Text(verbatim: source.sender)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
            Text(verbatim: source.subject)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, theme.space3)
            Spacer(minLength: theme.space5)
            Text(verbatim: model.dateText(source))
                .font(theme.typeMeta.swiftUIFont)
                .foregroundStyle(theme.textTertiary.color)
        }
    }

    private func plainRow(_ text: String, symbol: String, color: ThemeColor) -> some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: OverlayMetrics.rowIconSize))
                .foregroundStyle(color.color)
                .frame(width: OverlayMetrics.rowLabelX - OverlayMetrics.rowIconX, alignment: .leading)
                .padding(.leading, OverlayMetrics.rowIconX)
            Text(verbatim: text)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(color.color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: theme.space4) {
            Text(verbatim: model.footer)
                .font(theme.typeCaption.swiftUIFont)
                .foregroundStyle(theme.textTertiary.color)
                .lineLimit(1)
            Spacer(minLength: theme.space3)
            if let badge = model.badge { AIProviderBadgeView(badge: badge) }
        }
        .padding(.horizontal, OverlayMetrics.rowIconX)
        .frame(height: AskPanelMetrics.footerHeight)
    }
}
