import Foundation

extension AppSettings {
    public static let archiveSuggestionEnabled = AppSettingKey(name: "hygiene.suggest.enabled", defaultValue: true)
    public static let archiveSuggestionInboxThreshold = AppSettingKey(name: "hygiene.suggest.inbox_threshold",
                                                                      defaultValue: 1_000)
    public static let archiveSuggestionAgeDays = AppSettingKey(name: "hygiene.suggest.age_days", defaultValue: 14)
    public static let archiveSuggestionState = AppSettingKey(name: "hygiene.suggest.state",
                                                             defaultValue: ArchiveSuggestionSchedule())
    public static let archiveSuggestionOverrides = AppSettingKey<[String: String]>(name: "hygiene.suggest.overrides",
                                                                                  defaultValue: [:])

    public static let archiveSuggestionThresholdChoices = [250, 500, 1_000, 2_000, 5_000]
    public static let archiveSuggestionAgeChoices = [7, 14, 30, 90]
}

public struct ArchiveSuggestionSchedule: Sendable, Hashable, Codable {
    public static let interval: TimeInterval = 86_400
    public static let snoozeInterval: TimeInterval = 7 * 86_400

    public var lastOfferedAt: Date?
    public var hiddenUntil: Date?

    public init(lastOfferedAt: Date? = nil, hiddenUntil: Date? = nil) {
        self.lastOfferedAt = lastOfferedAt
        self.hiddenUntil = hiddenUntil
    }

    public func mayOffer(at now: Date, byUser: Bool = false) -> Bool {
        if byUser { return true }
        if let hiddenUntil, now < hiddenUntil { return false }
        guard let lastOfferedAt else { return true }
        return now.timeIntervalSince(lastOfferedAt) >= Self.interval
    }
}
