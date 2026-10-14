import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct LabelSidebarView: View {
    let router: AppRouter
    @Environment(\.theme) private var theme
    @State private var hovered: String?

    public init(router: AppRouter) {
        self.router = router
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if router.showsAccountSwitcher {
                    header("Accounts")
                    allInboxesRow()
                    ForEach(Array(router.accounts.enumerated()), id: \.element.id) { position, state in
                        accountRow(state, position: position + 1)
                    }
                    Color.clear.frame(height: theme.space4)
                }
                if let state = router.active {
                    header(router.showsAccountSwitcher ? (state.account.alias ?? state.account.email) : "Mailboxes")
                    ForEach(state.sidebarItems) { item in
                        row(item, isSelected: router.unifiedInbox == nil && item.location == state.location)
                    }
                }
            }
            .padding(.vertical, theme.space3)
        }
        .frame(width: theme.component.labelSidebar.width)
        .frame(maxHeight: .infinity)
        .background(theme.bgSidebar.color)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.borderHairline.color).frame(width: theme.borderWidthHairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Labels")
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(theme.typeLabel.swiftUIFont)
            .foregroundStyle(theme.component.labelSidebar.header.color)
            .lineLimit(1)
            .padding(.horizontal, theme.space5)
            .frame(height: theme.component.labelSidebar.rowHeight, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }

    private func allInboxesRow() -> some View {
        let isSelected = router.unifiedInbox != nil
        let key = "allInboxes"
        let tokens = theme.component.labelSidebar
        return Button {
            router.goToAllInboxes()
        } label: {
            HStack(spacing: theme.space3) {
                Image(systemName: "tray.2")
                    .font(.system(size: ShellMetrics.rowIconSize, weight: .regular))
                    .foregroundStyle((isSelected ? tokens.iconSelected : theme.textSecondary).color)
                    .frame(width: theme.space6)
                Text("All Inboxes")
                    .font((isSelected ? theme.typeBodyStrong : theme.typeBody).swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Spacer(minLength: theme.space3)
                if let count = router.allInboxesUnread, let text = SplitTabBar.countText(count) {
                    Text(text)
                        .font(theme.typeCaption.swiftUIFont)
                        .foregroundStyle(tokens.count.color)
                } else {
                    Text("⌃0")
                        .font(theme.typeMeta.swiftUIFont)
                        .foregroundStyle(tokens.count.color)
                }
            }
            .padding(.horizontal, theme.space5 - tokens.insetX)
            .frame(height: tokens.rowHeight)
            .modifier(SidebarPlate(isSelected: isSelected, isHovered: hovered == key))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hover(key, inside) }
        .help("Every account's inbox together  ⌃0  G U")
        .accessibilityLabel("All Inboxes")
        .accessibilityValue(router.allInboxesUnread.map { "\($0) unread" } ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accountRow(_ state: AccountState, position: Int) -> some View {
        let isActive = state.id == router.activeAccountID && router.unifiedInbox == nil
        let key = "account.\(state.id.rawValue)"
        let tokens = theme.component.labelSidebar
        return Button {
            router.switchAccount(to: state.id)
        } label: {
            HStack(spacing: theme.space3) {
                Text(state.account.alias ?? state.account.email)
                    .font((isActive ? theme.typeBodyStrong : theme.typeBody).swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Spacer(minLength: theme.space3)
                Text("⌃\(position)")
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(tokens.count.color)
            }
            .padding(.horizontal, theme.space5 - tokens.insetX)
            .frame(height: tokens.rowHeight)
            .modifier(SidebarPlate(isSelected: isActive, isHovered: hovered == key))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hover(key, inside) }
        .help(state.account.email)
        .accessibilityLabel(state.account.alias ?? state.account.email)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func row(_ item: SidebarItem, isSelected: Bool) -> some View {
        let key = "location.\(item.id)"
        let tokens = theme.component.labelSidebar
        return Button {
            router.go(to: item.location)
        } label: {
            HStack(spacing: theme.space3) {
                Image(systemName: item.symbol)
                    .font(.system(size: ShellMetrics.rowIconSize, weight: .regular))
                    .foregroundStyle((isSelected ? tokens.iconSelected : theme.textSecondary).color)
                    .frame(width: theme.space6)
                Text(item.title)
                    .font((isSelected ? theme.typeBodyStrong : theme.typeBody).swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                Spacer(minLength: theme.space3)
                if let count = item.count, let text = SplitTabBar.countText(count) {
                    Text(text)
                        .font(theme.typeCaption.swiftUIFont)
                        .foregroundStyle(tokens.count.color)
                }
            }
            .padding(.leading, theme.space5 - tokens.insetX + CGFloat(item.depth) * theme.space4)
            .padding(.trailing, theme.space5 - tokens.insetX)
            .frame(height: tokens.rowHeight)
            .modifier(SidebarPlate(isSelected: isSelected, isHovered: hovered == key))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hover(key, inside) }
        .accessibilityLabel(item.title)
        .accessibilityValue(item.count.map { "\($0)" } ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func hover(_ key: String, _ inside: Bool) {
        if inside { hovered = key } else if hovered == key { hovered = nil }
    }
}

private struct SidebarPlate: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let tokens = theme.component.labelSidebar
        let plate = RoundedRectangle(cornerRadius: tokens.radius)
        content
            .background {
                if isSelected {
                    plate.fill(tokens.bgSelected.color)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(tokens.bar.color).frame(width: theme.borderWidthCursorBar)
                        }
                        .clipShape(plate)
                } else if isHovered {
                    plate.fill(tokens.bgHover.color)
                }
            }
            .padding(.horizontal, tokens.insetX)
    }
}
