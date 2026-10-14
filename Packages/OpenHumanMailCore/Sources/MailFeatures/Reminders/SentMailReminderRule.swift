import Foundation
import MailModel

public struct SentMailReminderRule: Sendable, Hashable {
    public enum Scope: String, Sendable, Hashable, CaseIterable {
        case off
        case externalRecipients
        case needsFollowUp
    }

    public var enabled: Bool
    public var days: Int
    public var hour: Int
    public var weekdaysOnly: Bool
    public var aiDetected: Bool

    public init(enabled: Bool = AppSettings.autoRemindExternal.defaultValue,
                days: Int = AppSettings.autoRemindDays.defaultValue,
                hour: Int = AppSettings.autoRemindHour.defaultValue,
                weekdaysOnly: Bool = AppSettings.autoRemindWeekdaysOnly.defaultValue,
                aiDetected: Bool = AppSettings.autoRemindAIDetected.defaultValue) {
        self.enabled = enabled
        self.days = min(max(days, 1), 14)
        self.hour = min(max(hour, 0), 23)
        self.weekdaysOnly = weekdaysOnly
        self.aiDetected = aiDetected
    }

    public var scope: Scope { !enabled ? .off : (aiDetected ? .needsFollowUp : .externalRecipients) }

    public static func load(from settings: (any SettingsPort)?) async -> SentMailReminderRule {
        guard let settings else { return SentMailReminderRule() }
        return SentMailReminderRule(
            enabled: (try? await settings.get(AppSettings.autoRemindExternal)) ?? AppSettings.autoRemindExternal.defaultValue,
            days: (try? await settings.get(AppSettings.autoRemindDays)) ?? AppSettings.autoRemindDays.defaultValue,
            hour: (try? await settings.get(AppSettings.autoRemindHour)) ?? AppSettings.autoRemindHour.defaultValue,
            weekdaysOnly: (try? await settings.get(AppSettings.autoRemindWeekdaysOnly))
                ?? AppSettings.autoRemindWeekdaysOnly.defaultValue,
            aiDetected: (try? await settings.get(AppSettings.autoRemindAIDetected))
                ?? AppSettings.autoRemindAIDetected.defaultValue)
    }

    public static var genericDomains: Set<String> { ArchiveSuggestionRules.genericDomains }

    public static func hasExternalRecipient(_ recipients: [String], myAddresses: Set<String>) -> Bool {
        let mine = Set(myAddresses.map { $0.lowercased() })
        let ownDomains = Set(mine.compactMap(domain(of:))).subtracting(genericDomains)
        return recipients.contains { raw in
            let address = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !address.isEmpty, !mine.contains(address) else { return false }
            guard let domain = domain(of: address) else { return false }
            return !ownDomains.contains(domain)
        }
    }

    public static func mayNeedFollowUp(_ recipients: [String], myAddresses: Set<String>) -> Bool {
        let mine = Set(myAddresses.map { $0.lowercased() })
        return recipients.contains { raw in
            let address = raw.trimmingCharacters(in: .whitespaces).lowercased()
            return !address.isEmpty && address.contains("@") && !mine.contains(address) && !isNoReply(address)
        }
    }

    public static func isNoReply(_ address: String) -> Bool {
        guard let at = address.lastIndex(of: "@") else { return false }
        let local = address[..<at].lowercased().filter { $0.isLetter }
        return local.hasPrefix("noreply") || local.hasPrefix("donotreply") || local.hasSuffix("noreply")
            || local.hasSuffix("donotreply") || local == "mailerdaemon" || local == "postmaster"
    }

    public func dueDate(sentAt: Date, recipients: [String], myAddresses: Set<String>,
                        calendar: Calendar = .current) -> Date? {
        guard enabled, Self.hasExternalRecipient(recipients, myAddresses: myAddresses) else { return nil }
        return dueDate(after: sentAt, calendar: calendar)
    }

    public func dueDate(after sentAt: Date, calendar: Calendar = .current) -> Date? {
        dueDate(after: sentAt, days: days, calendar: calendar)
    }

    public func dueDate(after sentAt: Date, days count: Int, calendar: Calendar = .current) -> Date? {
        var day = calendar.startOfDay(for: sentAt)
        var remaining = min(max(count, 1), 14)
        var guardSteps = 0
        while remaining > 0, guardSteps < 60 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
            guardSteps += 1
            if !weekdaysOnly || !calendar.isDateInWeekend(day) { remaining -= 1 }
        }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }

    public func followUpDays(suggested: Int?) -> Int {
        guard let suggested else { return days }
        return min(days, min(max(suggested, 1), 14))
    }

    public func nextSlot(after now: Date, calendar: Calendar = .current) -> Date? {
        var day = calendar.startOfDay(for: now)
        for _ in 0..<10 {
            if let slot = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day), slot > now,
               !weekdaysOnly || !calendar.isDateInWeekend(day) {
                return slot
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    static func domain(of address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...].lowercased()
        return domain.isEmpty ? nil : domain
    }
}
