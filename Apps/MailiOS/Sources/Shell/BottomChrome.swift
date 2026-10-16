import MailFeatures
import MailModel
import SwiftUI

struct BottomChrome: View {
    let phone: PhoneMail
    @ScaledMetric(relativeTo: .body) private var avatar: CGFloat = 52
    @Environment(\.touch) private var theme

    var body: some View {
        HStack(spacing: theme.tokens.space3) {
            if phone.showsSplitStrip, !phone.tabs.isEmpty {
                SplitStrip(phone: phone)
            } else {
                Spacer(minLength: 0)
            }
            Button { phone.showsSettings = true } label: {
                let account = phone.active?.account
                let side = min(avatar, 72)
                AvatarView(name: account?.displayName, email: account?.email ?? "", size: side - 10)
                    .frame(width: side, height: side)
                    .background(Circle().fill(theme.pill))
                    .overlay(Circle().strokeBorder(theme.elevatedBorder, lineWidth: theme.tokens.borderWidthHairline))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings and account")
            .accessibilityIdentifier("chrome.settings")
        }
        .padding(.horizontal, theme.tokens.space4)
        .padding(.top, theme.tokens.space2)
        .padding(.bottom, theme.tokens.space1)
        .bottomBarBackground(theme.window)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { phone.chromeHeight = $0 }
    }
}

struct SplitStrip: View {
    let phone: PhoneMail
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 52
    @Environment(\.touch) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.tokens.space6) {
                    ForEach(phone.tabs) { tab in
                        let active = tab.location == phone.active?.location
                        let count = phone.active?.tabCount(tab) ?? tab.unread
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { phone.go(to: tab.location) }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: theme.tokens.space2) {
                                Text(tab.title)
                                    .font(active ? theme.tabActive : theme.tab)
                                    .foregroundStyle(active ? theme.tokens.component.tab.textActive.color
                                                     : theme.tokens.component.tab.text.color)
                                if count > 0 {
                                    Text("\(count)")
                                        .font(theme.tabCount)
                                        .foregroundStyle(theme.tokens.component.tab.count.color)
                                }
                            }
                            .fixedSize()
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .id(tab.location)
                        .accessibilityLabel(count > 0 ? "\(tab.title), \(count)" : tab.title)
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
                .padding(.horizontal, theme.tokens.space6)
            }
            .frame(height: min(height, 76))
            .background(Capsule().fill(theme.pill))
            .overlay(Capsule().strokeBorder(theme.elevatedBorder, lineWidth: theme.tokens.borderWidthHairline))
            .clipShape(Capsule())
            .onChange(of: phone.active?.location) { _, location in
                guard let location else { return }
                withAnimation { proxy.scrollTo(location, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Splits")
    }
}
