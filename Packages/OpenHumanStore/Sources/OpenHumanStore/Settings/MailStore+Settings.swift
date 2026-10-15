import Foundation
import GRDB
import OpenHumanCore

extension MailStore: SettingsStoring {
    public func setting<T: Codable & Sendable>(_ key: SettingKey<T>, scope: SettingScope) throws -> T {
        let json: String? = try read { db in
            try String.fetchOne(db, sql: "SELECT value_json FROM settings WHERE scope = ? AND key = ?",
                                arguments: [Self.scopeString(scope), key.name])
        }
        guard let json else { return key.defaultValue }
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            if key.isSafetyKey { throw StoreError.integrity("setting \(key.name) is unreadable") }
            return key.defaultValue
        }
    }

    public func setSetting<T: Codable & Sendable>(_ key: SettingKey<T>, _ value: T, scope: SettingScope) throws {
        let data: Data
        do { data = try JSONEncoder().encode(value) } catch { throw StoreError.integrity("setting \(key.name) is not encodable") }
        let json = String(decoding: data, as: UTF8.self)
        try write { db in
            if case let .account(id) = scope,
               try Int.fetchOne(db, sql: "SELECT 1 FROM accounts WHERE account_id = ?", arguments: [id.rawValue]) == nil {
                throw StoreError.notFound("account \(id.rawValue)")
            }
            let isReminderRuleKey = key.name.hasPrefix(SuperhumanReminderRule.keyPrefix)
            var previous: String?
            if isReminderRuleKey {
                previous = try String.fetchOne(db, sql: "SELECT value_json FROM settings WHERE scope = ? AND key = ?",
                                               arguments: [Self.scopeString(scope), key.name])
            }
            try Self.upsertSetting(scope: scope, key: key.name, json: json, in: db)
            if key.name == SettingKey<[String]>.alsoShowSplitInInbox.name || key.name == SettingKey<Int?>.eventsRescanAt.name,
               case let .account(id) = scope {
                try ThreadAggregator.reevaluateSplits(account: id.rawValue, in: db)
            }
            if isReminderRuleKey, json != previous {
                try SuperhumanReminderRule.settingChanged(key: key.name, scope: scope, previousJSON: previous, in: db)
            }
            // `settings` is WITHOUT ROWID so SQLite's update hook never fires for it; bumping the pulse row wakes observers
            try db.execute(sql: "UPDATE observation_pulse SET seq = seq + 1 WHERE id = 1")
        }
    }

    static func upsertSetting(scope: SettingScope, key: String, json: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO settings (scope, key, value_json, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(scope, key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at
            """, arguments: [scopeString(scope), key, json, nowMillis()])
    }

    static func scopeString(_ scope: SettingScope) -> String {
        switch scope {
        case .global: return "global"
        case let .account(id): return "account:\(id.rawValue)"
        }
    }
}

extension SettingKey where T == Int {
    public static var undoSendSeconds: SettingKey<Int> { .init(name: "undo_send_seconds", defaultValue: 10, isSafetyKey: false) }
    public static var undoSendSecondsRange: ClosedRange<Int> { 0...60 }
    public static var pollIntervalSeconds: SettingKey<Int> { .init(name: "poll_interval_seconds", defaultValue: 60, isSafetyKey: false) }
    public static var bodyHorizonDays: SettingKey<Int> { .init(name: "body_horizon_days", defaultValue: 90, isSafetyKey: false) }
}
extension SettingKey where T == Int? {
    public static var metadataHorizonDays: SettingKey<Int?> { .init(name: "metadata_horizon_days", defaultValue: nil, isSafetyKey: false) }
    public static var bodyMaxMessages: SettingKey<Int?> { .init(name: "sync.body_max_messages", defaultValue: nil, isSafetyKey: false) }
    public static var syncRequestAt: SettingKey<Int?> { .init(name: "sync.request_at", defaultValue: nil, isSafetyKey: false) }
    public static var eventsRescanAt: SettingKey<Int?> { .init(name: "split.events_rescan_at", defaultValue: nil, isSafetyKey: false) }
}
extension SettingKey where T == Bool {
    public static var snoozeMarkUnread: SettingKey<Bool> { .init(name: "snooze_mark_unread", defaultValue: true, isSafetyKey: false) }
    public static var schedulerSnoozeEnabled: SettingKey<Bool> { .init(name: "scheduler.snooze.enabled", defaultValue: true, isSafetyKey: false) }
    public static var schedulerSendLaterEnabled: SettingKey<Bool> { .init(name: "scheduler.send_later.enabled", defaultValue: true, isSafetyKey: false) }
    public static var schedulerRemindersEnabled: SettingKey<Bool> { .init(name: "scheduler.reminders.enabled", defaultValue: true, isSafetyKey: false) }
    public static var downloadBodies: SettingKey<Bool> { .init(name: "sync.download_bodies", defaultValue: true, isSafetyKey: false) }
    public static var cliReadonlyDefault: SettingKey<Bool> { .init(name: "cli.readonly_default", defaultValue: false, isSafetyKey: true) }
}
extension SettingKey where T == String? {
    public static var defaultAccount: SettingKey<String?> { .init(name: "default_account", defaultValue: nil, isSafetyKey: false) }
}
extension SettingKey where T == [String]? {
    public static var cliAllowedCommands: SettingKey<[String]?> { .init(name: "cli.allowed_commands", defaultValue: nil, isSafetyKey: true) }
}
extension SettingKey where T == String {
    public static var remoteImages: SettingKey<String> { .init(name: "remote_images", defaultValue: "block", isSafetyKey: false) }
}
extension SettingKey where T == [String] {
    public static var remoteImagesAllowedSenders: SettingKey<[String]> { .init(name: "remote_images.allowed_senders", defaultValue: [], isSafetyKey: false) }
    public static var hideSplitWhenEmpty: SettingKey<[String]> { .init(name: "split.hide_when_empty", defaultValue: [], isSafetyKey: false) }
    public static var alsoShowSplitInInbox: SettingKey<[String]> { .init(name: "split.also_show_in_inbox", defaultValue: [], isSafetyKey: false) }
}
