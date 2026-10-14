import MailFeatures
import MailTheme
import SwiftUI

struct QuickRepliesList: View {
    let model: QuickRepliesModel
    let use: (QuickReply) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredRow: Int?

    static func showsKeycap(isHovered: Bool, isSelected: Bool) -> Bool {
        isHovered || isSelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            HStack(spacing: theme.space3) {
                Text("Quick replies")
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                Spacer(minLength: theme.space4)
                if let badge = model.badge, model.phase == .ready { AIProviderBadgeView(badge: badge) }
            }
            switch model.phase {
            case .loading, .idle:
                HStack(spacing: theme.space3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(theme.bgSunken.color).frame(width: 96, height: theme.component.chipAI.height)
                    }
                    Text("Thinking…").font(theme.typeCaption.swiftUIFont).foregroundStyle(theme.textTertiary.color)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Writing quick replies"))
            case .ready:
                ForEach(model.options) { option in
                    row(option)
                }
            case .failed(let reason):
                HStack(spacing: theme.space3) {
                    Text(verbatim: reason).font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                    Button(String(localized: "Try again")) { model.retry() }
                        .ohLinkButtonStyle()
                        .font(theme.typeLabel.swiftUIFont)
                }
            case .unavailable(let reason):
                Text(verbatim: reason).font(theme.typeCaption.swiftUIFont).foregroundStyle(theme.textTertiary.color)
            }
            if model.isSuspicious { AISuspiciousLine() }
        }
    }

    private func row(_ option: QuickReply) -> some View {
        let selected = model.selection == option.id
        let keycap = Self.showsKeycap(isHovered: hoveredRow == option.id, isSelected: selected)
        let chip = theme.component.chipAI
        let shape = RoundedRectangle(cornerRadius: InstantReplyMetrics.chipCorner, style: .continuous)
        return Button { use(option) } label: {
            HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
                KeycapView(text: "⌘\(option.id + 1)")
                    .opacity(keycap ? 1 : 0)
                    .animation(InstantReplyStrip.hintMotion(revealing: keycap,
                                                            reduceMotion: reduceMotion || theme.reduceMotion,
                                                            reveal: theme.tokens.motion(theme.motionReveal,
                                                                                        transform: false)).animation,
                               value: keycap)
                Text(verbatim: option.label)
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle((selected ? theme.textPrimary : theme.textSecondary).color)
                    .padding(.horizontal, theme.space3)
                    .frame(minHeight: chip.height)
                    .background(shape.fill(selected ? theme.bgRowSelected.color : Color.clear))
                    .overlay(shape.strokeBorder(selected ? theme.borderControl.color : Color.clear,
                                                lineWidth: CGFloat(theme.borderWidthHairline)))
                Text(verbatim: option.body)
                    .font(theme.typeReader.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hoveredRow = inside ? option.id : (hoveredRow == option.id ? nil : hoveredRow) }
        .accessibilityLabel(option.label)
        .accessibilityValue(option.body)
        .accessibilityHint(String(localized: "Puts this reply into the draft. Nothing is sent."))
    }
}
