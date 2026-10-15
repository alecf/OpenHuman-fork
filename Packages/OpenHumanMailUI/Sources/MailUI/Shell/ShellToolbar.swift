import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct ShellToolbar: View {
    let router: AppRouter
    @Environment(\.theme) private var theme
    @Environment(\.titleBarInset) private var titleBarInset

    public init(router: AppRouter) {
        self.router = router
    }

    public var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: titleBarInset > 0 ? theme.component.toolbar.paddingX : ShellMetrics.trafficLightInset, height: 1)
            glyphButton("line.3.horizontal") { _ = router.perform(.toggleLabelSidebar, source: .toolbar) }
                .help("Labels  ⌃⌘S")
                .accessibilityLabel("Show or hide labels")
                .accessibilityHint("Control Command S")
            let calendarWindow = router.environment.calendarWindow
            if let calendarWindow {
                let open = calendarWindow.isOpen
                glyphButton(open ? "envelope" : "calendar") {
                    _ = router.perform(open ? .calendarBackToMail : .calendarOpen, source: .toolbar)
                }
                .help(open ? "Back to Mail  1" : "Calendar  2")
                .accessibilityLabel(open ? "Back to Mail" : "Calendar")
                .accessibilityHint(open ? "1" : "2")
                .accessibilityIdentifier("toolbar.calendar")
            }
            Color.clear.frame(width: theme.space3, height: 1)
            if router.showsAccountSwitcher {
                AccountSwitcherView(router: router)
                Color.clear.frame(width: theme.space7, height: 1)
            }
            if calendarWindow?.isOpen == true {
                Text("Calendar").font(theme.typeTabActive.swiftUIFont)
                    .foregroundStyle(theme.component.tab.textActive.color)
                    .padding(.horizontal, ShellMetrics.tabHitPadding)
                    .accessibilityAddTraits(.isHeader)
            } else if let unified = router.unifiedInbox {
                allInboxesTitle(unified)
            } else if let state = router.active {
                if state.searchOpen && state.mode == .list {
                    SearchFieldView(search: router.environment.overlays.search)
                } else if state.mode == .reader {
                    readerTitle(state)
                } else if state.isOnTab {
                    if let list = state.list { SelectAllCheckbox(list: list, descriptors: router.environment.actions.descriptors) }
                    SplitTabBar(router: router, state: state)
                } else if let location = state.location {
                    if let list = state.list { SelectAllCheckbox(list: list, descriptors: router.environment.actions.descriptors) }
                    locationTitle(state, location)
                }
            }
            Spacer(minLength: theme.space7)
            if router.environment.isFake {
                Text("Fake data")
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .padding(.trailing, theme.space5)
            }
            trailingControls
        }
        .padding(.trailing, theme.component.toolbar.paddingX)
        .frame(height: theme.component.toolbar.height)
        .frame(maxWidth: .infinity)
        .background(theme.component.toolbar.bg.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Toolbar")
    }

    private func readerTitle(_ state: AccountState) -> some View {
        HStack(spacing: theme.space5) {
            Button {
                router.closeReader()
            } label: {
                HStack(spacing: theme.space2) {
                    Image(systemName: "chevron.left").font(.system(size: ShellMetrics.smallIconSize, weight: .regular))
                    Text("Back").font(theme.typeBody.swiftUIFont)
                }
                .foregroundStyle(theme.textSecondary.color)
                .frame(height: ShellMetrics.toolbarControlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to the list  Esc")
            .accessibilityLabel("Back")
            .accessibilityHint("Escape")
        }
    }

    private func allInboxesTitle(_ model: AllInboxesModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.component.tab.countGap) {
            Text(model.title)
                .font(theme.typeTabActive.swiftUIFont)
                .foregroundStyle(theme.component.tab.textActive.color)
                .lineLimit(1)
            if let unread = router.allInboxesUnread, let text = SplitTabBar.countText(unread) {
                Text(text)
                    .font(theme.typeTabCount.swiftUIFont)
                    .foregroundStyle(theme.component.tab.count.color)
            }
        }
        .padding(.horizontal, ShellMetrics.tabHitPadding)
        .help(router.allInboxesUnread.map {
            AccountSwitcherView.countPhrase($0.formatted(), router.accountCountMode)
        } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func locationTitle(_ state: AccountState, _ location: MailLocation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.component.tab.countGap) {
            Text(state.title(for: location))
                .font(theme.typeTabActive.swiftUIFont)
                .foregroundStyle(theme.component.tab.textActive.color)
                .lineLimit(1)
            if let text = AccountState.titleCount(for: location, total: state.list?.totalCount) {
                Text(text)
                    .font(theme.typeTabCount.swiftUIFont)
                    .foregroundStyle(theme.component.tab.count.color)
            }
        }
        .padding(.horizontal, ShellMetrics.tabHitPadding)
        .help(Self.titleTooltip(state.list?.totalCount))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var trailingControls: some View {
        HStack(spacing: theme.space3) {
            let canCompose = router.isEnabled(.compose)
            glyphButton("square.and.pencil", enabled: canCompose) { _ = router.perform(.compose, source: .toolbar) }
                .help(canCompose ? "New message  C" : "Compose is not available here")
                .accessibilityLabel("Compose")
                .accessibilityHint("C")
            glyphButton("magnifyingglass", enabled: router.unifiedInbox == nil) { _ = router.perform(.search, source: .toolbar) }
                .help("Search  /")
                .accessibilityLabel("Search")
                .accessibilityHint("Slash")
        }
    }

    private func glyphButton(_ symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: theme.component.toolbar.iconSize, weight: .light))
                .frame(width: ShellMetrics.toolbarControlHeight, height: ShellMetrics.toolbarControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle((enabled ? theme.textTertiary : theme.textDisabled).color)
        .disabled(!enabled)
    }

    public static func conversationTitle(_ reader: ReaderModel?) -> String {
        guard let reader, !reader.messages.isEmpty else { return "" }
        let sender = reader.messages.last?.summary.from.map { ($0.name?.isEmpty == false ? $0.name : nil) ?? $0.email } ?? ""
        let count = reader.messages.count == 1 ? "1 message" : "\(reader.messages.count) messages"
        if sender.isEmpty { return reader.messages.count == 1 ? "" : count }
        return "\(sender) · \(count)"
    }

    static func titleTooltip(_ total: Int?) -> String {
        guard let total, total > 0 else { return "" }
        return total == 1 ? "1 conversation" : "\(total.formatted()) conversations"
    }
}
