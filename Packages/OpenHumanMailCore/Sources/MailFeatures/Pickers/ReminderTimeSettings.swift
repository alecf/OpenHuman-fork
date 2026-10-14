import Foundation
import MailModel

@MainActor
public final class ReminderTimeSettings {
    public private(set) var defaults: TimeDefaults
    private var minutes: Int
    private var weekdaysOnly: Bool
    private var tasks: [Task<Void, Never>] = []

    public init(settings: (any SettingsPort)?) {
        minutes = AppSettings.defaultReminderTime.defaultValue
        weekdaysOnly = AppSettings.reminderWeekdaysOnly.defaultValue
        defaults = TimeDefaults(defaultTime: minutes, weekdaysOnly: weekdaysOnly)
        guard let settings else { return }
        let time = settings.observe(AppSettings.defaultReminderTime)
        let weekdays = settings.observe(AppSettings.reminderWeekdaysOnly)
        tasks = [
            Task { [weak self] in
                for await value in time {
                    guard !Task.isCancelled else { return }
                    self?.update(minutes: value)
                }
            },
            Task { [weak self] in
                for await value in weekdays {
                    guard !Task.isCancelled else { return }
                    self?.update(weekdaysOnly: value)
                }
            },
        ]
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }

    private func update(minutes value: Int? = nil, weekdaysOnly only: Bool? = nil) {
        if let value { minutes = value }
        if let only { weekdaysOnly = only }
        let next = TimeDefaults(defaultTime: minutes, weekdaysOnly: weekdaysOnly)
        if next != defaults { defaults = next }
    }
}
