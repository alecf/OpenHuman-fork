import Foundation

extension AppSettings {
    public static let defaultReminderTime = AppSettingKey(name: "reminders.default_time", defaultValue: 540)
    public static let reminderWeekdaysOnly = AppSettingKey(name: "reminders.weekdays_only", defaultValue: false)

    public static let defaultReminderTimeChoices: [Int] = Array(stride(from: 360, through: 720, by: 30))
}
