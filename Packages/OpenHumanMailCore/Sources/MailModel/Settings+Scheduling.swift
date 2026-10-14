import Foundation

public enum CalendarHoldKind: String, Sendable, Hashable, Codable, CaseIterable {
    case tentative, busy
}

extension AppSettings {
    public static let calendarWorkdayStartHour = AppSettingKey(name: "calendar.workday_start_hour", defaultValue: 9)
    public static let calendarWorkdayEndHour = AppSettingKey(name: "calendar.workday_end_hour", defaultValue: 18)
    public static let calendarBufferMinutes = AppSettingKey(name: "calendar.buffer_minutes", defaultValue: 0)
    public static let calendarAcceptedHoldKind = AppSettingKey(name: "calendar.accepted_hold_kind",
                                                               defaultValue: CalendarHoldKind.tentative)
    public static let calendarSchedulingLink = AppSettingKey<String?>(name: "calendar.scheduling_link", defaultValue: nil)
    public static let calendarSuggestReplyTimes = AppSettingKey(name: "calendar.suggest_reply_times", defaultValue: true)
    public static let calendarOfferMoves = AppSettingKey(name: "calendar.offer_moves", defaultValue: true)
}

extension AppSettings {
    public static let aiSummarizeEveryConversation = AppSettingKey(name: "ai.summarize_every_conversation",
                                                                   defaultValue: true)
}
