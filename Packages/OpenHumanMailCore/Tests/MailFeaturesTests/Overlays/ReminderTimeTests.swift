import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private let zone = TimeZone(identifier: "UTC")!
private let wednesday = utc("2026-10-14T10:00:00Z")
private let friday = utc("2026-10-16T10:00:00Z")

@MainActor
@Suite struct ReminderTimeTests {
    @Test func theKeysAndTheirDefaults() {
        #expect(AppSettings.defaultReminderTime.name == "reminders.default_time")
        #expect(AppSettings.defaultReminderTime.defaultValue == 540, "9:00")
        #expect(AppSettings.reminderWeekdaysOnly.name == "reminders.weekdays_only")
        #expect(AppSettings.reminderWeekdaysOnly.defaultValue == false)
        #expect(AppSettings.defaultReminderTimeChoices.first == 360 && AppSettings.defaultReminderTimeChoices.last == 720)
        #expect(AppSettings.defaultReminderTimeChoices.contains(540) && AppSettings.defaultReminderTimeChoices.count == 13)
        let defaults = TimeDefaults(defaultTime: 570, weekdaysOnly: true)
        #expect(defaults.morningHour == 9 && defaults.morningMinute == 30 && defaults.weekdaysOnly)
        #expect(defaults.weekendHour == TimeDefaults().weekendHour && defaults.eveningHour == TimeDefaults().eveningHour)
        #expect(TimeDefaults(defaultTime: -5, weekdaysOnly: false).morningHour == 0)
        #expect(TimeDefaults(defaultTime: 5_000, weekdaysOnly: false).morningHour == 23)
    }

    @Test func theDefaultTimeMovesTheMorningPresets() {
        let presets = TimePresets(timeZone: zone, defaults: TimeDefaults(defaultTime: 570, weekdaysOnly: false))
        let remind = presets.presets(for: .remind, now: wednesday)
        #expect(remind.first { $0.id == "tomorrowMorning" }?.date == utc("2026-10-15T09:30:00Z"), "tomorrow morning")
        #expect(remind.first { $0.id == "inTwoDays" }?.date == utc("2026-10-16T09:30:00Z"), "in 2 days")
        #expect(remind.first { $0.id == "nextWeek" }?.date == utc("2026-10-19T09:30:00Z"), "next Monday")
        let snooze = presets.presets(for: .snooze, now: wednesday)
        #expect(snooze.first { $0.id == "tomorrowMorning" }?.date == utc("2026-10-15T09:30:00Z"))
        #expect(snooze.first { $0.id == "weekend" }?.date == utc("2026-10-17T09:00:00Z"), "the weekend keeps its own hour")
        let picker = TimePickerModel(kind: .remind, targets: [], presets: presets, locale: Locale(identifier: "en_US_POSIX"),
                                     now: { wednesday }) { _ in }
        picker.openDatePick()
        #expect(picker.datePick?.timeText == "09:30")
    }

    @Test func weekdaysOnlyMovesRemindAndSnoozeOffTheWeekend() {
        let on = TimePresets(timeZone: zone, defaults: TimeDefaults(defaultTime: 540, weekdaysOnly: true))
        let remind = on.presets(for: .remind, now: friday)
        #expect(remind.first { $0.id == "tomorrowMorning" }?.date == utc("2026-10-19T09:00:00Z"), "Saturday → Monday")
        #expect(remind.first { $0.id == "inTwoDays" }?.date == utc("2026-10-19T09:00:00Z"), "Sunday → Monday")
        let snooze = on.presets(for: .snooze, now: friday)
        #expect(snooze.first { $0.id == "tomorrowMorning" }?.date == utc("2026-10-19T09:00:00Z"))
        #expect(snooze.first { $0.id == "weekend" }?.date == utc("2026-10-17T09:00:00Z"), "This weekend stays")
        let later = on.presets(for: .sendLater, now: friday)
        #expect(later.first { $0.id == "tomorrowMorning" }?.date == utc("2026-10-17T09:00:00Z"), "send later is not moved")

        let off = TimePresets(timeZone: zone, defaults: TimeDefaults(defaultTime: 540, weekdaysOnly: false))
        #expect(off.presets(for: .remind, now: friday).first { $0.id == "tomorrowMorning" }?.date == utc("2026-10-17T09:00:00Z"), "off: Saturday it is")
        #expect(on.presets(for: .remind, now: wednesday).first { $0.id == "tomorrowMorning" }?.date == utc("2026-10-15T09:00:00Z"))
    }

    @Test func thePickersPaletteAndNotificationsFollowTheSettings() async throws {
        let f = SettingsFixture()
        let times = f.env.reminderTimes
        await eventually { times.defaults == TimeDefaults(defaultTime: 540, weekdaysOnly: false) }
        try await f.store.set(AppSettings.defaultReminderTime, 450)
        try await f.store.set(AppSettings.reminderWeekdaysOnly, true)
        await eventually { times.defaults == TimeDefaults(defaultTime: 450, weekdaysOnly: true) }
        #expect(f.env.overlays.timeDefaults == times.defaults, "the time pickers use them")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        #expect(NotificationService.remindTime(now: friday, calendar: calendar, defaults: times.defaults)
                == utc("2026-10-19T07:30:00Z"), "the notification's Remind button too")
        f.env.overlays.timeDefaults = TimeDefaults(morningHour: 7)
        #expect(f.env.overlays.timeDefaults.morningHour == 7)
    }

    @Test func theGeneralPageOffersHalfHoursAndKeepsAnotherStoredTime() async throws {
        let f = SettingsFixture(writePort: false)
        let model = GeneralSettingsModel(environment: f.env)
        model.start()
        #expect(model.defaultReminderTime.value == 540 && !model.reminderWeekdaysOnly.value)
        #expect(model.availability.canEditSettings, "local settings need no write port")
        await model.defaultReminderTime.set(480)
        await model.reminderWeekdaysOnly.set(true)
        #expect(try await f.store.get(AppSettings.defaultReminderTime) == 480)
        #expect(try await f.store.get(AppSettings.reminderWeekdaysOnly) == true)
        try await f.store.set(AppSettings.defaultReminderTime, 425)
        await eventually { model.defaultReminderTime.value == 425 }
        #expect(model.defaultReminderTimeChoices.contains(425) && model.defaultReminderTimeChoices.first == 360)
        let english = Locale(identifier: "en_US_POSIX")
        #expect(GeneralSettingsModel.defaultReminderTimeTitle(540, locale: english).replacingOccurrences(of: "\u{202F}", with: " ")
                == "9:00 AM")
        #expect(model.errorMessage == nil)
    }
}
