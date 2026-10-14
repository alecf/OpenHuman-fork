import MailFeatures
import MailTheme
import SwiftUI

public struct AIComposerPanel: View {
    @Bindable var model: AIComposerModel
    let center: AICenter?
    @FocusState private var focused: Bool
    @FocusState private var actionFocus: String?
    @State private var boxWidth: CGFloat = 0
    @Environment(\.theme) private var theme

    public init(model: AIComposerModel, center: AICenter?) {
        self.model = model
        self.center = center
    }

    public static let width: CGFloat = 480
    static let minWidth: CGFloat = 320
    static let previewMaxHeight: CGFloat = 240

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            if let version = model.currentVersion { versionText(version) }
            box
            if let consent = model.consent {
                AIConsentView(request: consent, center: center,
                              accept: { Task { await model.acceptConsent() } }, decline: { model.declineConsent() })
            }
            if case .failed(let reason) = model.phase {
                Text(verbatim: String(localized: "Couldn't write it: \(reason)"))
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer.ai.failure")
            }
            if model.showsExamples {
                AIExamplesPopover(width: AIComposerMetrics.examplesWidth(boxWidth: boxWidth), use: { example in
                    model.useExample(example)
                    focused = true
                }, close: { model.dismissExamples() })
            }
            if model.currentVersion == nil, model.instruction.isEmpty, let replies = model.quickReplies,
               replies.isOffered || replies.phase != .idle {
                QuickRepliesList(model: replies, use: { model.use($0) })
                    .padding(.top, theme.space1)
            }
        }
        .frame(minWidth: Self.minWidth, idealWidth: Self.width, maxWidth: .infinity, alignment: .leading)
        .background(PanelShortcuts(model: model))
        .onAppear {
            focused = true
            #if canImport(AppKit)
            if center?.pasteboard == nil { center?.pasteboard = AISystemPasteboard() }
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "AI: \(model.scopeTitle)"))
        .accessibilityIdentifier("composer.ai")
    }

    private var isEditBar: Bool { model.currentVersion != nil || model.scope != .notes }

    private var box: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusMD, style: .continuous)
        return VStack(alignment: .leading, spacing: theme.space2) {
            HStack(alignment: .center, spacing: theme.space3) {
                if model.phase == .working {
                    Text(AIComposerModel.workingText)
                        .font(theme.typeReader.swiftUIFont)
                        .foregroundStyle(theme.textTertiary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("composer.ai.working")
                } else if model.currentVersion != nil {
                    field(text: $model.editInstruction, placeholder: AIComposerModel.editPlaceholder,
                          submit: { model.submitEdit() })
                } else {
                    field(text: $model.instruction, placeholder: model.placeholder, submit: { model.submit() })
                }
                AISendButton(working: model.phase == .working, enabled: canSend,
                             send: { send() }, stop: { model.stop() })
            }
            .frame(minHeight: AIComposerMetrics.promptHeight)
            if isEditBar {
                AIEditActions(model: model, badge: model.currentVersion?.badge, focus: $actionFocus,
                              backToField: { actionFocus = nil; focused = true })
            }
        }
        .padding(.horizontal, theme.space4)
        .padding(.vertical, theme.space2)
        .background(shape.fill(theme.bgElevated.color))
        .overlay(shape.strokeBorder((focused ? theme.borderControl : theme.borderHairline).color,
                                    lineWidth: CGFloat(theme.borderWidthHairline)))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
    }

    private var canSend: Bool {
        if model.currentVersion != nil { return true }
        return !model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func enterActions() -> KeyPress.Result {
        guard isEditBar, model.phase != .working else { return .ignored }
        let first = model.currentVersion != nil ? "done" : model.editPresets.first?.id
        guard let first else { return .ignored }
        actionFocus = first
        return .handled
    }

    private func send() {
        if model.currentVersion != nil { model.submitEdit() } else { model.submit() }
    }

    private func field(text: Binding<String>, placeholder: String, submit: @escaping () -> Void) -> some View {
        TextField(model.scopeTitle, text: text, prompt: Text(placeholder).foregroundStyle(theme.textTertiary.color),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .font(theme.typeReader.swiftUIFont)
            .foregroundStyle(theme.textPrimary.color)
            .focused($focused)
            .onSubmit(submit)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) {
                    text.wrappedValue += "\n"
                    return .handled
                }
                if press.modifiers.contains(.option) {
                    model.insertBelow()
                    return .handled
                }
                submit()
                return .handled
            }
            .onKeyPress(.tab, phases: .down) { press in
                if press.modifiers.contains(.option) {
                    return enterActions()
                }
                if press.modifiers.contains(.shift) {
                    model.previousVersion()
                } else if model.currentVersion != nil {
                    model.retry()
                } else if !model.instruction.isEmpty {
                    model.generate()
                } else {
                    model.quickReplies?.selectNext()
                }
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard model.currentVersion == nil, model.instruction.isEmpty, let replies = model.quickReplies,
                      !replies.options.isEmpty else { return enterActions() }
                replies.selectNext()
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard model.currentVersion == nil, model.instruction.isEmpty, let replies = model.quickReplies,
                      !replies.options.isEmpty else { return .ignored }
                replies.selectPrevious()
                return .handled
            }
            .onKeyPress(.escape) {
                model.close()
                return .handled
            }
            .accessibilityLabel(placeholder)
            .accessibilityIdentifier("composer.ai.field")
    }

    private func versionText(_ version: AIComposerModel.Version) -> some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            ScrollView {
                Group {
                    if model.showsDiff, version.isComplete {
                        Text(diffText)
                    } else {
                        Text(verbatim: version.text.isEmpty ? " " : version.text)
                    }
                }
                .font(theme.typeReader.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .textSelection(.enabled)
                .padding(.horizontal, theme.space1)
                .background(RoundedRectangle(cornerRadius: theme.radiusXS).fill(theme.bgRowSelected.color))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: Self.previewMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            if version.isSuspicious { AISuspiciousLine() }
            if version.isTruncated {
                Text("The answer was cut at its length limit.")
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
            }
            if let counter = model.counterText {
                Text(verbatim: counter)
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .help(String(localized: "⇧⇥ the previous version, ⇥ another one"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Suggested text"))
        .accessibilityValue(version.text)
        .accessibilityIdentifier("composer.ai.version")
    }

    private var diffText: AttributedString {
        var out = AttributedString()
        for segment in model.diff {
            var run = AttributedString(segment.text)
            switch segment.kind {
            case .kept:
                break
            case .inserted:
                run.swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: theme.textPrimary.color)
            case .deleted:
                run.swiftUI.strikethroughStyle = Text.LineStyle(pattern: .solid, color: theme.textTertiary.color)
                run.swiftUI.foregroundColor = theme.textTertiary.color
            }
            out += run
        }
        return out
    }
}

enum AIComposerMetrics {
    static let promptHeight: CGFloat = 38
    static let fieldHeight: CGFloat = 32
    static let sendButton: CGFloat = 22
    static let sendTarget: CGFloat = 28

    static func examplesWidth(boxWidth: CGFloat) -> CGFloat {
        min(max(boxWidth * 0.5, 280), 360)
    }
}

private struct PanelShortcuts: View {
    let model: AIComposerModel

    var body: some View {
        ZStack {
            Button("") { model.showsDiff.toggle() }.keyboardShortcut("d", modifiers: .command)
            ForEach(0..<3, id: \.self) { index in
                Button("") {
                    guard let replies = model.quickReplies, replies.options.indices.contains(index) else { return }
                    model.use(replies.options[index])
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
