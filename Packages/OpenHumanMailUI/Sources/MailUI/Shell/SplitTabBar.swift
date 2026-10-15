import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct SplitTabBar: View {
    let router: AppRouter
    let state: AccountState
    @Environment(\.theme) private var theme

    public init(router: AppRouter, state: AccountState) {
        self.router = router
        self.state = state
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.component.tab.gap - 2 * ShellMetrics.tabHitPadding) {
                ForEach(state.tabs) { tab in
                    tabButton(tab, isActive: tab.location == state.location)
                }
            }
        }
        .frame(height: ShellMetrics.tabHeight)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split inbox")
    }

    private func tabButton(_ tab: MailTab, isActive: Bool) -> some View {
        let count = Self.countText(state.tabCount(tab))
        return Button {
            router.go(to: tab.location)
        } label: {
            tabLabel(tab.title, count: count, isActive: true)
                .hidden()
                .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                    tabLabel(tab.title, count: count, isActive: isActive)
                }
                .padding(.horizontal, ShellMetrics.tabHitPadding)
                .frame(height: ShellMetrics.tabHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let hidden = state.hidesWhenEmpty(tab.location) {
                Toggle("Hide when empty", isOn: Binding(get: { hidden }, set: { on in
                    Task { await state.setHidesWhenEmpty(tab.location, on) }
                }))
            }
        }
        .help(Self.tooltip(tab))
        .accessibilityLabel(tab.title)
        .accessibilityValue(Self.spokenCount(tab))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func tabLabel(_ title: String, count: String?, isActive: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.component.tab.countGap) {
            Text(title)
                .font((isActive ? theme.typeTabActive : theme.typeTab).swiftUIFont)
                .foregroundStyle((isActive ? theme.component.tab.textActive : theme.component.tab.text).color)
                .lineLimit(1)
            if let count {
                Text(count)
                    .font(theme.typeTabCount.swiftUIFont)
                    .foregroundStyle(theme.component.tab.count.color)
            }
        }
    }

    static func tooltip(_ tab: MailTab) -> String {
        switch (tab.unread > 0, tab.total) {
        case (true, let total?): "\(tab.title): \(Self.conversations(total)), \(tab.unread.formatted()) unread"
        case (true, nil): "\(tab.title): \(tab.unread.formatted()) unread"
        case (false, let total?): "\(tab.title): \(Self.conversations(total))"
        case (false, nil): tab.title
        }
    }

    static func spokenCount(_ tab: MailTab) -> String {
        var parts: [String] = []
        if let total = tab.total, total > 0 { parts.append(conversations(total)) }
        if tab.unread > 0 { parts.append("\(tab.unread.formatted()) unread") }
        return parts.joined(separator: ", ")
    }

    private static func conversations(_ n: Int) -> String {
        n == 1 ? "1 conversation" : "\(n.formatted()) conversations"
    }

    public static func countText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 999 ? "999+" : "\(count)"
    }
}
