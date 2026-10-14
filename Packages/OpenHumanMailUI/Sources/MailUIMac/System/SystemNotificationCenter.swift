import Foundation
import MailModel
import Synchronization
@preconcurrency import UserNotifications

public final class SystemNotificationCenter: NSObject, SystemNotifying, UNUserNotificationCenterDelegate, Sendable {
    static let markDoneAction = "mail.markDone"
    static let markReadAction = "mail.markRead"
    static let snoozeAction = "mail.snooze"
    static let remindIfNoReplyAction = "mail.remindIfNoReply"

    private let center: UNUserNotificationCenter
    private let responder = Mutex<(@MainActor @Sendable (NotificationResponse) -> Void)?>(nil)

    @MainActor
    public override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
        center.setNotificationCategories(Self.categories())
    }

    public func authorization() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .authorized
        @unknown default: .denied
        }
    }

    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    public func schedule(_ notification: SystemNotification) async {
        let request = UNNotificationRequest(identifier: notification.identifier, content: Self.content(for: notification),
                                            trigger: Self.trigger(for: notification.deliverAt))
        try? await center.add(request)
    }

    public func remove(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func pendingIdentifiers() async -> [String] { await center.pendingNotificationRequests().map(\.identifier) }

    public func deliveredIdentifiers() async -> [String] { await center.deliveredNotifications().map(\.request.identifier) }

    @MainActor public func setResponder(_ new: (@MainActor @Sendable (NotificationResponse) -> Void)?) {
        responder.withLock { $0 = new }
    }

    static func content(for notification: SystemNotification) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let subtitle = notification.subtitle { content.subtitle = subtitle }
        content.body = notification.body
        if let thread = notification.threadIdentifier { content.threadIdentifier = thread }
        if let category = notification.category { content.categoryIdentifier = category.rawValue }
        content.userInfo = notification.userInfo
        content.sound = .default
        return content
    }

    static func trigger(for date: Date?, calendar: Calendar = .current) -> UNNotificationTrigger? {
        guard let date else { return nil }
        let parts = calendar.dateComponents(in: calendar.timeZone, from: date)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        components.hour = parts.hour
        components.minute = parts.minute
        components.second = parts.second
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    static func categories() -> Set<UNNotificationCategory> {
        let done = UNNotificationAction(identifier: markDoneAction, title: "Mark done", options: [])
        let snooze = UNNotificationAction(identifier: snoozeAction, title: "Snooze", options: [])
        let remind = UNNotificationAction(identifier: remindIfNoReplyAction, title: "Remind if no reply", options: [])
        return [
            UNNotificationCategory(identifier: SystemNotification.Category.newMail.rawValue, actions: [done, snooze, remind],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: SystemNotification.Category.reminder.rawValue, actions: [done, snooze],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: SystemNotification.Category.readOnly.rawValue, actions: [],
                                   intentIdentifiers: [], options: []),
        ]
    }

    static func action(for identifier: String) -> NotificationResponse.Action? {
        switch identifier {
        case UNNotificationDefaultActionIdentifier: .open
        case markDoneAction: .markDone
        case markReadAction: .markRead
        case snoozeAction: .snooze
        case remindIfNoReplyAction: .remindIfNoReply
        default: nil
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let action = Self.action(for: response.actionIdentifier) else { return }
        let info = (response.notification.request.content.userInfo as? [String: String]) ?? [:]
        let value = NotificationResponse(identifier: response.notification.request.identifier, action: action, userInfo: info)
        let handler = responder.withLock { $0 }
        await MainActor.run { handler?(value) }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
