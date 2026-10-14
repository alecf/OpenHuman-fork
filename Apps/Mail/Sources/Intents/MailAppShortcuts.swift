import AppIntents

struct MailAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenMailboxIntent(), phrases: ["Open my inbox in \(.applicationName)"],
                    shortTitle: "Open inbox", systemImageName: "tray")
        AppShortcut(intent: NewMessageIntent(), phrases: ["New message in \(.applicationName)"],
                    shortTitle: "New message", systemImageName: "square.and.pencil")
        AppShortcut(intent: CountUnreadIntent(), phrases: ["How many important emails in \(.applicationName)"],
                    shortTitle: "Important unread", systemImageName: "envelope.badge")
    }
}
