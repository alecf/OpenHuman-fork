import Foundation
import OpenHumanCore

extension AppSettings {
    public static let superhumanRemindersHide = AppSettingKey(name: "superhuman_reminders.hide", defaultValue: true)
    public static let superhumanReminderSenders = AppSettingKey(name: "superhuman_reminders.senders",
                                                                defaultValue: [SuperhumanReminderEmail.documentedSender])
    public static let superhumanRemindersSince = AppSettingKey<Int64?>(name: "superhuman_reminders.since", defaultValue: nil)
    public static let superhumanRemindersBacklogImported = AppSettingKey(name: "superhuman_reminders.backlog_imported",
                                                                         defaultValue: false)
    public static let superhumanRemindersArchiveInGmail = AppSettingKey(name: "superhuman_reminders.archive_in_gmail",
                                                                        defaultValue: false)

    public static func superhumanRemindersConverted(_ account: AccountID) -> AppSettingKey<[String]> {
        AppSettingKey(name: "superhuman_reminders.converted", scope: .account(account), defaultValue: [])
    }

    public static func superhumanRemindersReturned(_ account: AccountID) -> AppSettingKey<[String: Int64]> {
        AppSettingKey(name: "superhuman_reminders.returned", scope: .account(account), defaultValue: [:])
    }

    public static func superhumanRemindersDismissed(_ account: AccountID) -> AppSettingKey<[String]> {
        AppSettingKey(name: "superhuman_reminders.dismissed", scope: .account(account), defaultValue: [])
    }
}

public struct SuperhumanReminderEmail: Sendable, Hashable, Identifiable {
    public static let documentedSender = "reminder@superhuman.com"

    public enum Match: Sendable, Hashable {
        case sameConversation
        case replyHeaders(ThreadKey)
        case unmatched
    }

    public let id: MessageKey
    public let thread: ThreadKey
    public let date: Date
    public let isInInbox: Bool
    public let isHidden: Bool
    public let match: Match
    public let subject: String
    public let targetInInbox: Bool

    public init(id: MessageKey, thread: ThreadKey, date: Date, isInInbox: Bool, isHidden: Bool, match: Match,
                subject: String, targetInInbox: Bool) {
        self.id = id
        self.thread = thread
        self.date = date
        self.isInInbox = isInInbox
        self.isHidden = isHidden
        self.match = match
        self.subject = subject
        self.targetInInbox = targetInInbox
    }

    public var target: ThreadKey? {
        switch match {
        case .sameConversation: thread
        case .replyHeaders(let key): key
        case .unmatched: nil
        }
    }
}
