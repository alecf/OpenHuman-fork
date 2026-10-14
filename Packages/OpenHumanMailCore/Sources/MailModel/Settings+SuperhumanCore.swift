import Foundation

extension AppSettings {
    public static let signatureOnReplies = AppSettingKey(name: "compose.signature_on_replies", defaultValue: true)

    public static let autoRemindExternal = AppSettingKey(name: "reminders.auto_external.enabled", defaultValue: false)
    public static let autoRemindDays = AppSettingKey(name: "reminders.auto_external.days", defaultValue: 3)
    public static let autoRemindHour = AppSettingKey(name: "reminders.auto_external.hour", defaultValue: 9)
    public static let autoRemindWeekdaysOnly = AppSettingKey(name: "reminders.auto_external.weekdays_only",
                                                             defaultValue: true)

    public static let autoRemindDayChoices = [1, 2, 3, 5, 7, 14]

    public static let autoRemindAIDetected = AppSettingKey(name: "reminders.auto_external.ai_detected", defaultValue: false)
}
