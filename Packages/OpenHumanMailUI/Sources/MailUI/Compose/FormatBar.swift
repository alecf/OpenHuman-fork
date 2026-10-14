import MailFeatures
import MailTheme
import SwiftUI

public struct FormatBarView: View {
    public enum Style: Sendable {
        case floating
        case inline
    }

    let state: ComposeFormatState
    let style: Style
    let action: (ComposeFormatCommand) -> Void
    @Environment(\.theme) private var theme

    public init(state: ComposeFormatState, style: Style, action: @escaping (ComposeFormatCommand) -> Void) {
        self.state = state
        self.style = style
        self.action = action
    }

    public var body: some View {
        HStack(spacing: FormatBarMetrics.spacing) {
            ForEach(Array(ComposeFormatCommand.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Rectangle()
                        .fill(theme.borderHairline.color)
                        .frame(width: theme.borderWidthHairline, height: FormatBarMetrics.separatorHeight)
                        .padding(.horizontal, FormatBarMetrics.spacing)
                        .accessibilityHidden(true)
                }
                ForEach(group) { command in button(command) }
            }
            if style == .inline { Spacer(minLength: 0) }
        }
        .padding(.horizontal, style == .floating ? FormatBarMetrics.floatingPadding : 0)
        .padding(.leading, style == .inline ? -FormatBarMetrics.glyphInset : 0)
        .frame(height: FormatBarMetrics.height)
        .background {
            if style == .floating {
                RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgElevated.color)
            }
        }
        .overlay {
            if style == .floating {
                RoundedRectangle(cornerRadius: theme.radiusMD)
                    .strokeBorder(theme.borderElevated.color, lineWidth: theme.borderWidthHairline)
            }
        }
        .themeShadow(style == .floating ? theme.shadow1 : .none)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formatting")
        .accessibilityIdentifier(style == .floating ? "composer.formatBar.floating" : "composer.formatBar")
    }

    private func button(_ command: ComposeFormatCommand) -> some View {
        let active = state.isActive(command)
        return Button { action(command) } label: {
            Image(systemName: Self.symbol(command))
                .font(.system(size: FormatBarMetrics.glyph, weight: .medium))
                .foregroundStyle((active ? theme.accentText : theme.textSecondary).color)
                .frame(width: FormatBarMetrics.button, height: FormatBarMetrics.button)
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusMD))
        }
        .buttonStyle(.plain)
        .help(command.help)
        .accessibilityLabel(command.title)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("composer.format.\(command.rawValue)")
    }

    static func symbol(_ command: ComposeFormatCommand) -> String {
        switch command {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .link: "link"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .quote: "text.quote"
        case .clearFormatting: "eraser"
        }
    }
}

public enum FormatBarMetrics {
    public static let height: CGFloat = 32
    static let button: CGFloat = 28
    static let spacing: CGFloat = 2
    static let separatorHeight: CGFloat = 16
    static let floatingPadding: CGFloat = 2
    static let glyph: CGFloat = 13
    static var glyphInset: CGFloat { (button - glyph) / 2 }
}
