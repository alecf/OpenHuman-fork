import Foundation
import MailModel
import Testing
@preconcurrency import UserNotifications
@testable import MailSystem

struct SystemPlatformTests {
    @Test func contentCarriesTitleBodyCategoryThreadAndOnlyRoutingValues() {
        let note = SystemNotification(identifier: "newmail.1.1", title: "Ada", body: "Subject", threadIdentifier: "account.1",
                                      category: .newMail, userInfo: ["account": "1", "row": "2", "gmail": "t"])
        let content = SystemNotificationCenter.content(for: note)
        #expect(content.title == "Ada" && content.body == "Subject")
        #expect(content.categoryIdentifier == "newMail" && content.threadIdentifier == "account.1")
        #expect(content.userInfo as? [String: String] == ["account": "1", "row": "2", "gmail": "t"])
        #expect(content.subtitle.isEmpty, "no account name with one account")
        let named = SystemNotificationCenter.content(for: SystemNotification(identifier: "newmail.2.1", title: "Ada",
                                                                             subtitle: "Work", body: "Subject"))
        #expect(named.subtitle == "Work", "the account is named when there are two")
    }

    @Test func aDueDateBecomesACalendarTriggerInTheCurrentCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 7200).rounded(.down))
        let trigger = try #require(SystemNotificationCenter.trigger(for: date, calendar: calendar) as? UNCalendarNotificationTrigger)
        #expect(!trigger.repeats)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(trigger.dateComponents.hour == parts.hour && trigger.dateComponents.minute == parts.minute)
        #expect(trigger.dateComponents.timeZone == calendar.timeZone)
        #expect(trigger.nextTriggerDate() == date, "the trigger fires at the due time")
        #expect(SystemNotificationCenter.trigger(for: nil) == nil)
    }

    @Test func twoCategoriesNewMailOffersMarkDoneSnoozeAndRemindIfNoReplyButNeverReply() {
        let categories = Dictionary(uniqueKeysWithValues: SystemNotificationCenter.categories().map { ($0.identifier, $0) })
        #expect(categories["newMail"]?.actions.map(\.title) == ["Mark done", "Snooze", "Remind if no reply"])
        #expect(categories["reminder"]?.actions.map(\.title) == ["Mark done", "Snooze"])
        #expect(categories.count == 2, "no reply, no send action")
        let titles = categories.values.flatMap(\.actions).map { $0.title.lowercased() }
        #expect(!titles.contains { $0.contains("reply") && !$0.contains("no reply") } && !titles.contains { $0.contains("send") })
        #expect(categories.values.flatMap(\.actions).allSatisfy { $0.options.isEmpty })
    }

    @Test func actionIdentifiersMapToResponses() {
        #expect(SystemNotificationCenter.action(for: UNNotificationDefaultActionIdentifier) == .open)
        #expect(SystemNotificationCenter.action(for: "mail.markDone") == .markDone)
        #expect(SystemNotificationCenter.action(for: "mail.markRead") == .markRead)
        #expect(SystemNotificationCenter.action(for: "mail.snooze") == .snooze)
        #expect(SystemNotificationCenter.action(for: "mail.remindIfNoReply") == .remindIfNoReply)
        #expect(SystemNotificationCenter.action(for: UNNotificationDismissActionIdentifier) == nil)
        #expect(SystemNotificationCenter.action(for: "reply") == nil)
    }
}
