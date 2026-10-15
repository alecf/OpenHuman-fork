import MailActions
import MailFeatures
import MailTheme
import SwiftUI

struct SelectAllCheckbox: View {
    let list: ThreadListModel
    let descriptors: [ActionDescriptor]
    @Environment(\.theme) private var theme
    @Environment(\.selectAllTipPinned) private var tipPinned
    @State private var hovering = false
    @State private var showsTip = false

    var body: some View {
        let check = list.headerCheck
        if check == .hidden {
            Color.clear
                .frame(width: ShellMetrics.toolbarControlHeight, height: ShellMetrics.toolbarControlHeight)
                .padding(.trailing, theme.space3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            let rows = SelectAllShortcuts.tipRows(descriptors)
            let tip = (showsTip || tipPinned) && !rows.isEmpty
            Button {
                hovering = false
                showsTip = false
                list.headerCheckClicked()
            } label: {
                SelectCheckboxGlyph(checked: check == .all)
                    .frame(width: ShellMetrics.toolbarControlHeight, height: ShellMetrics.toolbarControlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .onDisappear {
                hovering = false
                showsTip = false
            }
            .task(id: hovering) {
                guard hovering else {
                    showsTip = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(Int(theme.motionTooltipDelay.rounded())))
                if !Task.isCancelled { showsTip = true }
            }
            .anchorPreference(key: SelectAllTipKey.self, value: .bounds) { anchor in
                tip ? SelectAllTipRequest(anchor: anchor, rows: rows) : nil
            }
            .padding(.trailing, theme.space3)
            .accessibilityLabel(check == .all ? "Clear selection" : "Select all")
            .accessibilityValue(check == .all ? "All conversations checked" : "Some conversations checked")
            .accessibilityHint(Self.spokenHint(rows))
            .accessibilityIdentifier("toolbar.selectAll")
        }
    }

    static func spokenHint(_ rows: [SelectAllShortcuts.TipRow]) -> String {
        rows.map { "\($0.title): \(SelectAllShortcuts.spoken($0.keycaps))" }.joined(separator: ". ")
    }
}

extension EnvironmentValues {
    @Entry public var selectAllTipPinned = false
}

struct SelectAllTipRequest {
    let anchor: Anchor<CGRect>
    let rows: [SelectAllShortcuts.TipRow]
}

struct SelectAllTipKey: PreferenceKey {
    static var defaultValue: SelectAllTipRequest? { nil }

    static func reduce(value: inout SelectAllTipRequest?, nextValue: () -> SelectAllTipRequest?) {
        if value == nil { value = nextValue() }
    }
}

struct SelectAllTipLayer: View {
    let request: SelectAllTipRequest
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let button = proxy[request.anchor]
            SelectAllTip(rows: request.rows)
                .fixedSize()
                .padding(.leading, max(0, button.minX))
                .padding(.top, button.maxY + theme.space2)
        }
        .allowsHitTesting(false)
        .transaction { $0.disablesAnimations = true }
    }
}

struct SelectAllTip: View {
    let rows: [SelectAllShortcuts.TipRow]
    @Environment(\.theme) private var theme

    var body: some View {
        let toast = theme.component.toast
        Grid(alignment: .leading, horizontalSpacing: theme.space6, verticalSpacing: theme.space3) {
            ForEach(rows, id: \.title) { row in
                GridRow {
                    Text(row.title).font(theme.typeBody.swiftUIFont)
                    ToastKeycapRow(keycaps: row.keycaps).gridColumnAlignment(.trailing)
                }
            }
        }
        .foregroundStyle(toast.text.color)
        .padding(.horizontal, theme.space4)
        .padding(.vertical, theme.space3)
        .background(RoundedRectangle(cornerRadius: toast.radius).fill(toast.bg.color))
        .themeShadow(theme.shadow2)
        .accessibilityHidden(true)
    }
}

struct ToastKeycapRow: View {
    let keycaps: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        let toast = theme.component.toast
        HStack(spacing: theme.space2) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(theme.typeKeycap.swiftUIFont)
                    .foregroundStyle(toast.keycapText.color)
                    .padding(.horizontal, theme.space2)
                    .frame(minWidth: theme.component.keycap.minWidth, minHeight: theme.component.keycap.height)
                    .background(RoundedRectangle(cornerRadius: theme.component.keycap.radius).fill(toast.keycapBg.color))
            }
        }
        .accessibilityHidden(true)
    }
}

struct CheckBeforeHint: View {
    let list: ThreadListModel
    let keycaps: [String]
    @Environment(\.theme) private var theme

    var body: some View {
        let toast = theme.component.toast
        HStack(spacing: theme.space3) {
            HStack(spacing: theme.space3) {
                Text("Want to select everything before this conversation? Hit")
                    .font(theme.typeBody.swiftUIFont)
                    .lineLimit(1)
                HStack(spacing: theme.space1) {
                    ToastKeycapRow(keycaps: keycaps)
                    Text("!").font(theme.typeBody.swiftUIFont)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            Button { list.selection.checkBeforeHintDismissed = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: ShellMetrics.smallIconSize, weight: .regular))
                    .foregroundStyle(toast.textSecondary.color)
                    .frame(width: toast.closeSize, height: toast.closeSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(toast.text.color)
        .padding(.leading, theme.space5)
        .padding(.trailing, theme.space3)
        .frame(minHeight: toast.height)
        .background(RoundedRectangle(cornerRadius: toast.radius).fill(toast.bg.color))
        .themeShadow(theme.shadow2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selection.checkBeforeHint")
        .onAppear { AccessibilityNotification.Announcement(spoken).post() }
    }

    var spoken: String {
        "Want to select everything before this conversation? Press \(SelectAllShortcuts.spoken(keycaps))."
    }

    static func shows(router: AppRouter) -> CheckBeforeHint? {
        guard router.mode == .list, router.unifiedInbox == nil, let list = router.active?.list,
              list.offersCheckBefore else { return nil }
        let keycaps = SelectAllShortcuts.keycaps(for: SelectAllShortcuts.commandA, in: router.environment.actions.descriptors)
        return keycaps.isEmpty ? nil : CheckBeforeHint(list: list, keycaps: keycaps)
    }
}
