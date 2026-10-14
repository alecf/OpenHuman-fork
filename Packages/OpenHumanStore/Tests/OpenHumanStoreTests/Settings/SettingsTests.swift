import Foundation
import GRDB
import OpenHumanCore
import Testing
@testable import OpenHumanStore

@Suite struct SettingsTests {
    private func fixture() throws -> (MailStore, AccountID) {
        let store = try MailStore.openInMemoryForTesting()
        return (store, try store.addAccount(email: "me@example.com", displayName: nil, scopes: []))
    }

    @Test func defaultsMatchTheSpecTable() throws {
        let (store, account) = try fixture()
        #expect(try store.setting(.undoSendSeconds, scope: .global) == 10)
        #expect(try store.setting(.pollIntervalSeconds, scope: .global) == 60)
        #expect(try store.setting(.bodyHorizonDays, scope: .account(account)) == 90)
        #expect(try store.setting(.metadataHorizonDays, scope: .account(account)) == nil)
        #expect(try store.setting(.snoozeMarkUnread, scope: .global) == true)
        #expect(try store.setting(.schedulerSnoozeEnabled, scope: .global) == true)
        #expect(try store.setting(.schedulerSendLaterEnabled, scope: .global) == true)
        #expect(try store.setting(.schedulerRemindersEnabled, scope: .global) == true)
        #expect(try store.setting(.defaultAccount, scope: .global) == nil)
        #expect(try store.setting(.syncRequestAt, scope: .global) == nil)
        #expect(try store.setting(.cliReadonlyDefault, scope: .global) == false)
        #expect(try store.setting(.cliAllowedCommands, scope: .global) == nil)
        #expect(try store.setting(.remoteImages, scope: .account(account)) == "block")
        #expect(try store.setting(.remoteImagesAllowedSenders, scope: .account(account)) == [])
    }

    @Test func safetyKeysAreMarkedAndTheRestAreNot() {
        #expect(SettingKey.cliReadonlyDefault.isSafetyKey && SettingKey.cliAllowedCommands.isSafetyKey)
        #expect(!SettingKey.undoSendSeconds.isSafetyKey && !SettingKey.remoteImages.isSafetyKey)
        #expect(SettingKey.syncRequestAt.name == "sync.request_at")
        #expect(SettingKey.schedulerSendLaterEnabled.name == "scheduler.send_later.enabled")
    }

    @Test func roundTripsEveryValueShape() throws {
        let (store, account) = try fixture()
        try store.setSetting(.undoSendSeconds, 30, scope: .global)
        try store.setSetting(.metadataHorizonDays, 365, scope: .account(account))
        try store.setSetting(.defaultAccount, "me@example.com", scope: .global)
        try store.setSetting(.cliAllowedCommands, ["threads list", "search"], scope: .global)
        try store.setSetting(.remoteImagesAllowedSenders, ["a@example.com", "@news.example.com"], scope: .account(account))
        try store.setSetting(.snoozeMarkUnread, false, scope: .global)
        #expect(try store.setting(.undoSendSeconds, scope: .global) == 30)
        #expect(try store.setting(.metadataHorizonDays, scope: .account(account)) == 365)
        #expect(try store.setting(.defaultAccount, scope: .global) == "me@example.com")
        #expect(try store.setting(.cliAllowedCommands, scope: .global) == ["threads list", "search"])
        #expect(try store.setting(.remoteImagesAllowedSenders, scope: .account(account)) == ["a@example.com", "@news.example.com"])
        #expect(try store.setting(.snoozeMarkUnread, scope: .global) == false)
        try store.setSetting(.defaultAccount, nil, scope: .global)
        #expect(try store.setting(.defaultAccount, scope: .global) == nil)
    }

    @Test func scopesAreIndependentAndStoredAsSpecified() throws {
        let (store, account) = try fixture()
        let second = try store.addAccount(email: "two@example.com", displayName: nil, scopes: [])
        try store.setSetting(.bodyHorizonDays, 30, scope: .account(account))
        #expect(try store.setting(.bodyHorizonDays, scope: .account(account)) == 30)
        #expect(try store.setting(.bodyHorizonDays, scope: .account(second)) == 90)
        #expect(try store.setting(.bodyHorizonDays, scope: .global) == 90)
        let scopes = try store.read { try String.fetchAll($0, sql: "SELECT scope FROM settings WHERE key = 'body_horizon_days'") }
        #expect(scopes == ["account:\(account.rawValue)"])
    }

    @Test func overwriteKeepsOneRowAndUpdatesTheTimestamp() throws {
        let (store, _) = try fixture()
        try store.setSetting(.undoSendSeconds, 5, scope: .global)
        try store.setSetting(.undoSendSeconds, 20, scope: .global)
        let rows = try store.read { try Row.fetchAll($0, sql: "SELECT value_json, updated_at FROM settings WHERE key = 'undo_send_seconds'") }
        #expect(rows.count == 1 && rows[0]["value_json"] as String == "20" && (rows[0]["updated_at"] as Int64) > 0)
    }

    @Test func unknownKeysAreAllowedForTheUI() throws {
        let (store, _) = try fixture()
        let key = SettingKey<[String: Int]>(name: "ui.sidebar_widths", defaultValue: [:], isSafetyKey: false)
        try store.setSetting(key, ["left": 220], scope: .global)
        #expect(try store.setting(key, scope: .global) == ["left": 220])
    }

    @Test func accountScopeNeedsAnExistingAccount() throws {
        let (store, _) = try fixture()
        #expect(throws: StoreError.notFound("account 999")) { try store.setSetting(.bodyHorizonDays, 10, scope: .account(AccountID(999))) }
    }

    @Test func accountSettingsDieWithTheAccount() throws {
        let (store, account) = try fixture()
        try store.setSetting(.bodyHorizonDays, 10, scope: .account(account))
        try store.removeAccountData(account) { _ in }
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM settings WHERE scope = ?", arguments: ["account:\(account.rawValue)"]) } == 0)
    }

    @Test func unreadableValuesFallBackToDefaultsExceptSafetyKeys() throws {
        let (store, _) = try fixture()
        try store.write { db in
            try db.execute(sql: "INSERT INTO settings (scope, key, value_json, updated_at) VALUES ('global', 'undo_send_seconds', '\"not a number\"', 0)")
            try db.execute(sql: "INSERT INTO settings (scope, key, value_json, updated_at) VALUES ('global', 'cli.readonly_default', '{', 0)")
        }
        #expect(try store.setting(.undoSendSeconds, scope: .global) == 10)
        #expect(throws: StoreError.integrity("setting cli.readonly_default is unreadable")) {
            try store.setting(.cliReadonlyDefault, scope: .global)
        }
    }

    @Test func settingsWritesBumpTheChangeFeed() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try changeFeedSeq(store)
        try store.setSetting(.syncRequestAt, 1_790_000_000_000, scope: .global)
        #expect(try changeFeedSeq(store) == before + 1)
    }
}
