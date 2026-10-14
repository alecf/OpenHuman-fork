import Foundation
import MailFeatures
import MailModel
import Testing
@testable import MailUI

@Test func tabCountTextHidesZeroAndCapsAt999() {
    #expect(SplitTabBar.countText(0) == nil)
    #expect(SplitTabBar.countText(42) == "42")
    #expect(SplitTabBar.countText(999) == "999")
    #expect(SplitTabBar.countText(1_000) == "999+")
    let tab = MailTab(location: .splitOther, title: "Other", unread: 12, total: 4_598)
    #expect(SplitTabBar.tooltip(tab) == "Other: \(4_598.formatted()) conversations, 12 unread")
    #expect(SplitTabBar.spokenCount(tab) == "\(4_598.formatted()) conversations, 12 unread")
}

@Test func aTwoChoiceToastIsSpokenWithBothChoices() {
    var toast = Toast(message: "Unsubscribe request sent", style: .info, actionTitle: "Mark all from sender done",
                      postedAt: Date(), expiresAt: nil)
    toast.secondaryActionTitle = "Trash all from sender"
    #expect(ToastHostView.spoken(toast)
            == "Unsubscribe request sent. Mark all from sender done. Trash all from sender.")
}
