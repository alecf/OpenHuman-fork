import MailFeatures
import MailModel
import SwiftUI

struct MailboxesSheet: View {
    let phone: PhoneMail
    @Environment(\.touch) private var theme

    var body: some View {
        NavigationStack {
            List {
                if phone.router.showsAccountSwitcher {
                    Section("Accounts") {
                        ForEach(phone.router.accounts) { state in
                            let current = state.id == phone.active?.id
                            Button { phone.router.switchAccount(to: state.id) } label: {
                                row(title: state.account.email, symbol: "person.crop.circle", count: nil, selected: current)
                            }
                            .listRowBackground(theme.sidebar)
                        }
                    }
                }
                Section {
                    ForEach(phone.active?.sidebarItems ?? []) { item in
                        Button { phone.go(to: item.location) } label: {
                            row(title: item.title, symbol: item.symbol, count: item.count,
                                selected: item.location == phone.active?.location, depth: item.depth)
                        }
                        .listRowBackground(theme.sidebar)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.sidebar)
            .navigationTitle("Mailboxes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { phone.showsMailboxes = false }
                }
            }
        }
    }

    private func row(title: String, symbol: String, count: Int?, selected: Bool, depth: Int = 0) -> some View {
        HStack(spacing: theme.tokens.space3) {
            Image(systemName: symbol)
                .font(theme.smallIcon)
                .foregroundStyle(selected ? theme.accent : theme.textSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(selected ? theme.bodyStrong : theme.body)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let count, count > 0 {
                Text("\(count)")
                    .font(theme.snippet)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.leading, CGFloat(depth) * theme.tokens.space4)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
