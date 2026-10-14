import MailFeatures
import MailTheme
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

enum OverlayMetrics {
    static let paletteListMaxHeight: CGFloat = 420
    static let windowMargin: CGFloat = 96
    static let rowIconSize: CGFloat = 16
    static let rowIconX: CGFloat = 16
    static let rowLabelX: CGFloat = 44
    static let cursorInset: CGFloat = 4
    static let labelPickerWidth: CGFloat = 400
    static let timePickerWidth: CGFloat = 420
    static let timePickerTop: CGFloat = 120
    static let pickerInputHeight: CGFloat = 52
    static let footerHeight: CGFloat = 32
    static let calendarCell: CGFloat = 32
    static let checkboxSize: CGFloat = 14
    static let colorDot: CGFloat = 8

    #if canImport(AppKit)
    @MainActor private static var fieldLineHeights: [TypeStyle: CGFloat] = [:]

    @MainActor static func fieldLineHeight(_ style: TypeStyle) -> CGFloat {
        if let height = fieldLineHeights[style] { return height }
        let field = NSTextField(string: "Ag")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = style.fieldFont
        let height = ceil(field.intrinsicContentSize.height)
        fieldLineHeights[style] = height
        return height
    }
    #endif
}

#if canImport(AppKit)
private extension TypeStyle {
    var fieldFont: NSFont {
        let weight: NSFont.Weight = switch swiftUIWeight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign? = switch family {
        case .system, .named: nil
        case .systemSerif: .serif
        case .systemRounded: .rounded
        case .systemMono: .monospaced
        }
        if case .named(let name) = family { return NSFont(name: name, size: size) ?? system }
        if let design, let descriptor = system.fontDescriptor.withDesign(design),
           let designed = NSFont(descriptor: descriptor, size: size) {
            return designed
        }
        return system
    }
}
#endif

extension View {
    @MainActor func overlayInputLine(_ style: TypeStyle) -> some View {
        #if canImport(AppKit)
        frame(height: OverlayMetrics.fieldLineHeight(style))
        #else
        fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

extension EnvironmentValues {
    @Entry var overlaySheet: Bool = false
}

@MainActor
enum OverlaySheet {
    private static var twins: [String: ResolvedTheme] = [:]

    static func theme(for theme: ResolvedTheme) -> ResolvedTheme {
        guard theme.appearance != .dark else { return theme }
        let key = "\(theme.accentID)|\(theme.tokens.density)|\(theme.tokens.reduceMotion)"
        if let twin = twins[key] { return twin }
        let resolved = ThemeLibrary.builtIn.resolve(themeID: BuiltinThemeID.dark, appearance: .dark,
                                                    preferences: ThemePreferences(accentID: theme.accentID,
                                                                                  density: theme.tokens.density))
        var tokens = resolved.tokens
        tokens.reduceMotion = theme.tokens.reduceMotion
        let twin = ResolvedTheme(themeID: resolved.themeID, themeName: resolved.themeName, accentID: resolved.accentID,
                                 appearance: .dark, tokens: tokens, emailColors: resolved.emailColors, issues: resolved.issues)
        twins[key] = twin
        return twin
    }
}

struct KeycapView: View {
    let text: String
    @Environment(\.theme) private var theme
    @Environment(\.overlaySheet) private var onSheet

    var body: some View {
        let keycap = theme.component.keycap
        let palette = theme.component.palette
        Text(text)
            .font(theme.typeKeycap.swiftUIFont)
            .foregroundStyle((onSheet ? palette.keycapText : keycap.text).color)
            .padding(.horizontal, theme.space2)
            .frame(minWidth: keycap.minWidth, minHeight: keycap.height)
            .background(RoundedRectangle(cornerRadius: keycap.radius).fill((onSheet ? palette.keycapBg : keycap.bg).color))
            .overlay(RoundedRectangle(cornerRadius: keycap.radius)
                .strokeBorder((onSheet ? Color.clear : keycap.border.color), lineWidth: theme.borderWidthHairline))
            .accessibilityHidden(true)
    }
}

struct KeycapRow: View {
    let keycaps: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: keycaps.count > 1 ? 6 : 2) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in KeycapView(text: cap) }
        }
    }
}

struct HighlightedText: View {
    let text: String
    let matched: [Int]
    var color: ThemeColor? = nil
    var style: TypeStyle? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        Text(attributed)
            .font((style ?? theme.typeBody).swiftUIFont)
            .foregroundStyle((color ?? theme.textPrimary).color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        var strongStyle = style ?? theme.typeBodyStrong
        strongStyle.weight = theme.typeBodyStrong.weight
        let strong = strongStyle.swiftUIFont
        for offset in Set(matched) where offset >= 0 && offset < text.count {
            let start = result.characters.index(result.startIndex, offsetBy: offset)
            let end = result.characters.index(start, offsetBy: 1)
            result[start..<end].font = strong
        }
        return result
    }
}

struct OverlayGroupHeader: View {
    let title: String
    let height: CGFloat
    @Environment(\.theme) private var theme
    @Environment(\.overlaySheet) private var onSheet

    var body: some View {
        Text(title)
            .font(theme.typeLabel.swiftUIFont)
            .foregroundStyle((onSheet ? theme.component.palette.text : theme.textTertiary).color)
            .padding(.leading, OverlayMetrics.rowIconX)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct CursorRowBackground: View {
    let isCursor: Bool
    @Environment(\.theme) private var theme
    @Environment(\.overlaySheet) private var onSheet

    var body: some View {
        if isCursor, onSheet {
            let palette = theme.component.palette
            RoundedRectangle(cornerRadius: palette.cursorInset > 0 ? theme.radiusMD : 0)
                .fill(palette.band.color)
                .padding(.horizontal, palette.cursorInset)
        } else if isCursor {
            RoundedRectangle(cornerRadius: theme.radiusMD)
                .fill(theme.bgRowSelected.color)
                .overlay(alignment: .leading) {
                    Capsule().fill(theme.component.row.cursorBar.color).frame(width: theme.component.row.cursorBarWidth)
                        .padding(.vertical, 6)
                }
                .padding(.horizontal, OverlayMetrics.cursorInset)
        }
    }
}

struct OverlaySheetTitle<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.theme) private var theme

    var body: some View {
        let palette = theme.component.palette
        HStack(spacing: theme.space3) {
            CircledSymbol(symbol: symbol, color: palette.header)
            Text(title)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(palette.header.color)
                .lineLimit(1)
            Spacer(minLength: theme.space5)
            trailing
        }
        .padding(.horizontal, OverlayMetrics.rowIconX)
        .frame(height: palette.titleHeight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension OverlaySheetTitle where Trailing == EmptyView {
    init(symbol: String, title: String) {
        self.init(symbol: symbol, title: title) { EmptyView() }
    }
}

struct CircledSymbol: View {
    let symbol: String
    let color: ThemeColor
    @Environment(\.theme) private var theme

    var body: some View {
        let size = OverlayMetrics.rowIconSize + theme.space3
        if symbol.isEmpty {
            Color.clear.frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Image(systemName: symbol)
                .font(.system(size: OverlayMetrics.rowIconSize * 0.75, weight: .regular))
                .foregroundStyle(color.color)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(color.color, lineWidth: theme.borderWidthHairline))
                .accessibilityHidden(true)
        }
    }
}

struct OverlaySheetDivider: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.component.palette.divider.color)
            .frame(height: theme.borderWidthHairline)
            .padding(.horizontal, OverlayMetrics.rowIconX)
    }
}

struct OverlayInputBar: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.component.row.cursorBar.color)
            .frame(width: theme.component.row.cursorBarWidth)
            .accessibilityHidden(true)
    }
}

struct OverlayCard<Content: View>: View {
    let width: CGFloat
    let top: CGFloat
    let radius: CGFloat
    var sheet: Bool = false
    var topRatio: CGFloat = 0
    let dismiss: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme
    @State private var entered = false

    var body: some View {
        let tokens = theme.tokens
        let enter = tokens.motion(tokens.motionEnterFast)
        let settled = entered || !enter.animates
        let moves = !settled && enter.allowsTransform
        let surface = sheet ? tokens.component.palette.bg : theme.bgElevated
        let inner = sheet ? OverlaySheet.theme(for: theme) : theme
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                theme.bgScrim.color
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)
                content
                    .environment(\.theme, inner)
                    .environment(\.overlaySheet, sheet)
                    .environment(\.colorScheme, inner.appearance == .dark ? .dark : .light)
                    .tint(inner.tokens.component.row.cursorBar.color)
                    .transaction { $0.disablesAnimations = true }
                    .frame(width: min(width, max(proxy.size.width - OverlayMetrics.windowMargin, 280)))
                    .background(RoundedRectangle(cornerRadius: radius).fill(surface.color))
                    .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(theme.borderElevated.color, lineWidth: theme.borderWidthHairline))
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                    .themeShadow(theme.shadow3)
                    .opacity(settled ? 1 : 0)
                    .scaleEffect(moves ? tokens.component.overlay.enterScale : 1, anchor: .top)
                    .offset(y: moves ? -tokens.component.overlay.enterOffset : 0)
                    .padding(.top, max(top, (proxy.size.height * topRatio).rounded()))
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
            }
        }
        .onAppear { withAnimation(enter.animation) { entered = true } }
    }
}

extension View {
    func overlayKeys(up: @escaping () -> Void, down: @escaping () -> Void, escape: @escaping () -> Void) -> some View {
        onKeyPress(.upArrow) { up(); return .handled }
            .onKeyPress(.downArrow) { down(); return .handled }
            .onKeyPress(.escape) { escape(); return .handled }
    }
}
