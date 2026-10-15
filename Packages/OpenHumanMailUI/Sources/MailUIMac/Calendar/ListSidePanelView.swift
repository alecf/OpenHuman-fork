import MailActions
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI

struct ListSidePanelView: View {
    let router: AppRouter
    let panel: ListSidePanel

    var body: some View {
        switch panel {
        case .shortcuts:
            ShortcutsPanel(sections: SelectModeShortcuts.sections(router.environment.actions.descriptors))
        case .recentOpens:
            RecentOpensPanel(router: router)
        }
    }

    static func panel(for router: AppRouter) -> ListSidePanel {
        ListSidePanel.state(checkedCount: router.active?.selection.checked.count ?? 0)
    }
}

struct ShortcutsPanel: View {
    let sections: [SelectModeShortcuts.Section]
    @Environment(\.theme) private var theme

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: theme.space6, verticalSpacing: theme.space3) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                GridRow {
                    Text(section.title).themeFont(theme.typeLabel).foregroundStyle(theme.textTertiary.color)
                        .padding(.top, index == 0 ? 0 : theme.space3)
                        .accessibilityAddTraits(.isHeader)
                        .gridCellColumns(2)
                }
                ForEach(section.items) { item in
                    GridRow {
                        Text(item.title).themeFont(theme.typeBody).foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                            .accessibilityValue(SelectAllShortcuts.spoken(item.keycaps))
                        HStack(spacing: theme.space2) {
                            ForEach(Array(item.keycaps.enumerated()), id: \.offset) { _, cap in keycap(cap) }
                        }
                        .accessibilityHidden(true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("listPanel.shortcuts")
    }

    private func keycap(_ text: String) -> some View {
        let keycap = theme.component.keycap
        return Text(text)
            .font(theme.typeKeycap.swiftUIFont)
            .foregroundStyle(keycap.text.color)
            .padding(.horizontal, theme.space2)
            .frame(minWidth: keycap.minWidth, minHeight: keycap.height)
            .background(RoundedRectangle(cornerRadius: keycap.radius).fill(keycap.bg.color))
            .overlay(RoundedRectangle(cornerRadius: keycap.radius)
                .strokeBorder(keycap.border.color, lineWidth: theme.borderWidthHairline))
    }
}

struct RecentOpensPanel: View {
    let router: AppRouter
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space5) {
            let entries = router.recentOpens.entries
            if entries.isEmpty {
                Text("Conversations you open show up here.")
                    .themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
            } else {
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: theme.space5) {
                        ForEach(RecentOpenGroup.groups(entries, now: context.date)) { group in
                            section(group)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("listPanel.recentOpens")
    }

    private func section(_ group: RecentOpenGroup) -> some View {
        VStack(alignment: .leading, spacing: theme.space4) {
            if let title = group.title {
                Text(title).themeFont(theme.typeLabel).foregroundStyle(theme.textTertiary.color)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(group.lines) { line in
                Button { open(line.entry.id) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
                            Text(line.entry.sender).themeFont(theme.typeBodyStrong).foregroundStyle(theme.textPrimary.color)
                                .lineLimit(1).truncationMode(.tail)
                            Text(line.stamp).themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
                                .lineLimit(1).fixedSize()
                        }
                        Text(line.entry.subject.isEmpty ? "(no subject)" : line.entry.subject)
                            .themeFont(theme.typeBody).foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func open(_ key: ThreadKey) {
        if key.account != router.active?.id { router.switchAccount(to: key.account) }
        router.open(key)
    }
}
