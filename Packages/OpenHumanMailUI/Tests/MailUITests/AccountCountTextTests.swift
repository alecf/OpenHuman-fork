import MailModel
import Testing
@testable import MailUI

@MainActor
@Test func theSpokenValueNamesWhatIsCounted() {
    #expect(AccountSwitcherView.unreadValue(12, .important) == "12 important unread")
    #expect(AccountSwitcherView.unreadValue(99, .inbox) == "99 unread in Inbox")
    #expect(AccountSwitcherView.unreadValue(150, .inbox) == "More than 99 unread in Inbox")
    #expect(AccountSwitcherView.unreadValue(150, .important) == "More than 99 important unread")
}

@MainActor
@Test func theAllInboxesTooltipGivesTheExactCountAndWhatItCounts() {
    #expect(AccountSwitcherView.allInboxesTooltip(12, .important) == "All Inboxes · 12 important unread  ⌃0")
    #expect(AccountSwitcherView.allInboxesTooltip(150, .inbox)
            == "All Inboxes · \(150.formatted()) unread in Inbox  ⌃0")
    #expect(AccountSwitcherView.allInboxesTooltip(nil, .off) == "All Inboxes  ⌃0")
    #expect(AccountSwitcherView.allInboxesTooltip(0, .important) == "All Inboxes  ⌃0")
}

@MainActor
@Test func aTitleTooltipKeepsTheExactTotal() {
    #expect(ShellToolbar.titleTooltip(nil) == "")
    #expect(ShellToolbar.titleTooltip(0) == "")
    #expect(ShellToolbar.titleTooltip(1) == "1 conversation")
    #expect(ShellToolbar.titleTooltip(48_213) == "\(48_213.formatted()) conversations")
}
