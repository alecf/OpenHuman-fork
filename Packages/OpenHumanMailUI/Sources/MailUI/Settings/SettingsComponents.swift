import MailFeatures
import MailTheme
import SwiftUI

public enum SettingsMetrics {
    public static let sidebarWidth: CGFloat = 200
    public static let sidebarRowHeight: CGFloat = 28
    public static let sidebarIconSize: CGFloat = 14
    public static let contentMaxWidth: CGFloat = 640
    public static let rowMinHeight: CGFloat = 40
    public static let compactRowMinHeight: CGFloat = 28
    public static let windowWidth: CGFloat = 780
    public static let windowHeight: CGFloat = 560
    public static let revealSeconds: Double = 2.5
}

public enum SettingsTone: Sendable, Hashable {
    case secondary, warning, danger, success

    func color(_ theme: ResolvedTheme) -> Color {
        switch self {
        case .secondary: theme.textSecondary.color
        case .warning: theme.textWarning.color
        case .danger: theme.textDanger.color
        case .success: theme.textSuccess.color
        }
    }
}

public struct SettingsPageScaffold<Content: View>: View {
    public enum Layout: Sendable { case column, fill }

    let title: String
    let layout: Layout
    let content: Content
    @Environment(\.theme) private var theme
    @Environment(\.settingsReveal) private var reveal

    public init(title: String, layout: Layout = .column, @ViewBuilder content: () -> Content) {
        self.title = title
        self.layout = layout
        self.content = content()
    }

    public var body: some View {
        Group {
            switch layout {
            case .column:
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        stack
                            .frame(maxWidth: SettingsMetrics.contentMaxWidth, alignment: .leading)
                            .padding(theme.space8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicatorsFlash(onAppear: true)
                    .task(id: reveal?.serial) {
                        guard reveal != nil else { return }
                        // Why: the page (and a tab the result lives on) has to lay out before its row can be scrolled to
                        try? await Task.sleep(for: .milliseconds(150))
                        withAnimation { proxy.scrollTo(SettingsRevealHighlight.anchor, anchor: .center) }
                    }
                }
            case .fill:
                stack
                    .padding(theme.space8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(theme.bgWindow.color)
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: theme.space7) {
            Text(title).themeFont(theme.typeTitle).foregroundStyle(theme.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

public struct SettingsSection<Content: View>: View {
    let title: String?
    let detail: String?
    let footnote: String?
    let compact: Bool
    let content: Content
    @Environment(\.theme) private var theme
    @Environment(\.settingsReveal) private var reveal

    public init(_ title: String? = nil, detail: String? = nil, footnote: String? = nil, compact: Bool = false,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.footnote = footnote
        self.compact = compact
        self.content = content()
    }

    public var body: some View {
        Group(subviews: content.environment(\.settingsCompactRows, compact)) { rows in
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: theme.space3) {
                    if let title {
                        Text(title).themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
                            .accessibilityAddTraits(.isHeader)
                            .modifier(SettingsRevealHighlight(isOn: reveal?.entry.kind == .section && reveal?.entry.title == title))
                    }
                    if let detail {
                        SettingsFootnote(detail)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            if row.id != rows.first?.id {
                                Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
                                    .accessibilityHidden(true)
                            }
                            row
                        }
                    }
                    .padding(.horizontal, theme.space4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgSunken.color))
                    .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
                        .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
                    if let footnote {
                        SettingsFootnote(footnote).padding(.horizontal, theme.space4)
                    }
                }
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var settingsCompactRows = false
    @Entry var settingsReveal: SettingsReveal? = nil
}

/// Marks the row or section a Settings search result opened, and gives the page's scroll view something to scroll to.
struct SettingsRevealHighlight: ViewModifier {
    static let anchor = "settings.reveal"

    let isOn: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.accentSubtle.color)
                        .padding(.horizontal, -theme.space2)
                        .id(Self.anchor)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .animation(.easeOut(duration: 0.4), value: isOn)
    }
}

public struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    let status: String?
    let statusTone: SettingsTone
    let alignment: VerticalAlignment
    let labelsControl: Bool
    let stacked: Bool
    let control: Control
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsCompactRows) private var compact
    @Environment(\.settingsReveal) private var reveal

    public init(_ title: String, detail: String? = nil, status: String? = nil, statusTone: SettingsTone = .secondary,
                alignment: VerticalAlignment = .center, labelsControl: Bool = false, stacked: Bool = false,
                @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.status = status
        self.statusTone = statusTone
        self.alignment = alignment
        self.labelsControl = labelsControl
        self.stacked = stacked
        self.control = control()
    }

    public var body: some View {
        arranged
            .padding(.vertical, compact ? theme.space2 : theme.space3)
            .frame(minHeight: compact ? SettingsMetrics.compactRowMinHeight : SettingsMetrics.rowMinHeight)
            .modifier(SettingsRevealHighlight(isOn: reveal?.entry.kind == .row && reveal?.entry.title == title))
    }

    // Why: a wide control beside the title squeezes the title until it wraps a letter per line
    @ViewBuilder private var arranged: some View {
        if stacked {
            VStack(alignment: .leading, spacing: theme.space2) {
                text
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(RowTextAccessibility(hidden: labelsControl))
                control
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(RowControlAccessibility(label: labelsControl ? title : nil, hint: labelsControl ? spokenDetail : nil))
            }
        } else {
            HStack(alignment: alignment, spacing: theme.space5) {
                text
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(RowTextAccessibility(hidden: labelsControl))
                control
                    .fixedSize(horizontal: true, vertical: false)
                    .modifier(RowControlAccessibility(label: labelsControl ? title : nil, hint: labelsControl ? spokenDetail : nil))
            }
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: theme.space1) {
            Text(title).themeFont(theme.typeBody).foregroundStyle((isEnabled ? theme.textPrimary : theme.textTertiary).color)
            if let detail {
                Text(detail).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
            }
            if let status {
                Text(status).themeFont(theme.typeMeta).foregroundStyle(statusTone.color(theme))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var spokenDetail: String? {
        let lines = [detail, status].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

extension SettingsRow where Control == EmptyView {
    public init(_ title: String, detail: String? = nil, status: String? = nil, statusTone: SettingsTone = .secondary) {
        self.init(title, detail: detail, status: status, statusTone: statusTone) { EmptyView() }
    }
}

extension SettingsRow where Control == SettingsSwitch {
    public init(_ title: String, detail: String? = nil, status: String? = nil, statusTone: SettingsTone = .secondary,
                isOn: Binding<Bool>) {
        self.init(title, detail: detail, status: status, statusTone: statusTone, labelsControl: true) {
            SettingsSwitch(title: title, isOn: isOn)
        }
    }
}

extension SettingsRow {
    public init<Value: Hashable, Options: View>(_ title: String, detail: String? = nil, status: String? = nil,
                                                statusTone: SettingsTone = .secondary, selection: Binding<Value>,
                                                @ViewBuilder options: () -> Options)
        where Control == SettingsMenu<Value, Options> {
        let menu = SettingsMenu(title: title, selection: selection, options: options())
        self.init(title, detail: detail, status: status, statusTone: statusTone, labelsControl: true) { menu }
    }
}

public struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool

    public var body: some View {
        Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
    }
}

public struct SettingsMenu<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    let options: Options

    public var body: some View {
        Picker(title, selection: $selection) { options }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
    }
}

private struct RowTextAccessibility: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if hidden {
            content.accessibilityHidden(true)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

private struct RowControlAccessibility: ViewModifier {
    let label: String?
    let hint: String?

    func body(content: Content) -> some View {
        if let label, let hint {
            content.accessibilityLabel(Text(label)).accessibilityHint(Text(hint))
        } else if let label {
            content.accessibilityLabel(Text(label))
        } else {
            content
        }
    }
}

extension View {
    public func settingsRowPadding() -> some View {
        modifier(SettingsRowPadding())
    }
}

private struct SettingsRowPadding: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.vertical, theme.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct SettingsSectionStack<Content: View>: View {
    let content: Content
    @Environment(\.theme) private var theme

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space7) {
            content
        }
    }
}

public struct SettingsFootnote: View {
    let text: String
    let tone: SettingsTone
    @Environment(\.theme) private var theme

    public init(_ text: String, tone: SettingsTone = .secondary) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text).themeFont(theme.typeMeta).foregroundStyle(tone.color(theme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    public func settingsTextField() -> some View {
        modifier(SettingsTextFieldStyle())
    }
}

extension Text {
    public func settingsPrompt(_ theme: ResolvedTheme) -> Text {
        foregroundStyle(theme.textTertiary.color)
    }
}

private struct SettingsTextFieldStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .themeFont(theme.typeBody)
            .padding(.horizontal, theme.space2)
            .padding(.vertical, theme.space1)
            .background(RoundedRectangle(cornerRadius: theme.radiusSM).fill(theme.bgWindow.color))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusSM)
                .strokeBorder(theme.borderControl.color, lineWidth: theme.borderWidthControl))
    }
}

// Why: a fixed width keeps neighbouring fields aligned and stops one from widening as it is typed in
struct SettingsTextArea: View {
    static let width: CGFloat = 320

    let title: String
    let prompt: String
    @Binding var text: String
    @Environment(\.theme) private var theme

    var body: some View {
        TextField(title, text: $text, prompt: Text(verbatim: prompt).settingsPrompt(theme), axis: .vertical)
            .lineLimit(2...5)
            .labelsHidden()
            .settingsTextField()
            .frame(width: Self.width)
    }
}

struct SettingsErrorLine: View {
    let text: String?

    var body: some View {
        if let text { SettingsFootnote(text, tone: .danger) }
    }
}

typealias SettingsNote = SettingsFootnote

extension View {
    func settingsSectionLabel(_ theme: ResolvedTheme) -> some View {
        themeFont(theme.typeLabel).foregroundStyle(theme.textTertiary.color).accessibilityAddTraits(.isHeader)
    }
}
