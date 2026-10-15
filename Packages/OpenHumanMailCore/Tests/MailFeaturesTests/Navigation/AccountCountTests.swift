import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct AccountCountTests {
    private static func twoAccounts(_ mode: AccountCountMode) -> [Int?] {
        [AccountState.badgeCount(importantUnread: 3, inboxUnread: 250, firstTabUnread: 9, mode: mode),
         AccountState.badgeCount(importantUnread: nil, inboxUnread: 40, firstTabUnread: 4, mode: mode)]
    }

    @Test func allInboxesCountsImportantUnreadByDefault() {
        let total = AppRouter.allInboxesCount(Self.twoAccounts(AppSettings.accountCounts.defaultValue))
        #expect(total == 7)
        #expect(AccountState.switcherBadge(total ?? 0) == "7")
    }

    @Test func allInboxesCountsTheWholeInboxWhenAsked() {
        let total = AppRouter.allInboxesCount(Self.twoAccounts(.inbox))
        #expect(total == 290)
        #expect(AccountState.switcherBadge(total ?? 0) == "99+")
    }

    @Test func offRemovesEveryAccountNumber() {
        for important in [nil, 0, 3, 250] as [Int?] {
            for inbox in [nil, 0, 40] as [Int?] {
                #expect(AccountState.badgeCount(importantUnread: important, inboxUnread: inbox, firstTabUnread: 12,
                                                mode: .off) == nil)
            }
        }
        let total = AppRouter.allInboxesCount(Self.twoAccounts(.off))
        #expect(total == nil)
        #expect(AccountState.switcherBadge(total ?? 0) == nil)
    }

    @Test func anAccountWithNoImportantMailShowsNothingAsBefore() {
        #expect(AccountState.badgeCount(importantUnread: 0, inboxUnread: 40, firstTabUnread: 12, mode: .important) == 0)
        #expect(AccountState.switcherBadge(0) == nil)
        #expect(AccountState.badgeCount(importantUnread: 0, inboxUnread: 40, firstTabUnread: 12, mode: .inbox) == 40)
    }

    @Test func countsNotLoadedYetFallBackToTheFirstTab() {
        #expect(AccountState.badgeCount(importantUnread: nil, inboxUnread: nil, firstTabUnread: 5, mode: .important) == 5)
        #expect(AccountState.badgeCount(importantUnread: nil, inboxUnread: nil, firstTabUnread: 5, mode: .inbox) == 5)
    }

    @Test func aZeroSumShowsNothing() {
        #expect(AppRouter.allInboxesCount([0, 0]) == nil)
        #expect(AppRouter.allInboxesCount([nil, 0]) == nil)
        #expect(AppRouter.allInboxesCount([]) == nil)
        #expect(AppRouter.allInboxesCount([0, 1]) == 1)
    }

    @Test func theAccountCountsKeyDefaultsToImportant() {
        #expect(AppSettings.accountCounts.name == "ui.account_counts")
        #expect(AppSettings.accountCounts.scope == .global)
        #expect(AppSettings.accountCounts.defaultValue == .important)
        #expect(!AppSettings.accountCounts.isSafetyKey)
        #expect(AccountCountMode.allCases.map(\.rawValue) == ["important", "inbox", "off"])
        #expect(AppSettings.allInboxesShown.name == "ui.all_inboxes")
        #expect(AppSettings.allInboxesShown.scope == .global)
        #expect(AppSettings.allInboxesShown.defaultValue)
    }

    @Test func anUnreadableStoredModeReadsAsImportant() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(AccountCountMode.self, from: Data(#""inbox""#.utf8)) == .inbox)
        #expect(try decoder.decode(AccountCountMode.self, from: Data(#""off""#.utf8)) == .off)
        #expect(try decoder.decode(AccountCountMode.self, from: Data(#""later""#.utf8)) == .important)
        #expect(String(decoding: try JSONEncoder().encode(AccountCountMode.off), as: UTF8.self) == #""off""#)
    }

    @Test func theSettingsPickerUsesPlainWords() {
        #expect(AccountCountMode.allCases.map { GeneralSettingsModel.accountCountTitle($0) }
                == ["Important unread", "All unread in Inbox", "Off"])
    }

    @Test func theSettingsPickerStoresTheChosenMode() async throws {
        let f = SettingsFixture()
        let model = GeneralSettingsModel(environment: f.env)
        #expect(model.accountCounts.value == .important)
        await model.accountCounts.set(.off)
        #expect(model.accountCounts.value == .off)
        #expect(try await f.store.get(AppSettings.accountCounts) == .off)
    }

    @Test func archiveViewsShowNoTitleNumber() {
        #expect(AccountState.titleCount(for: .system(.allMail), total: 48_213) == nil)
        #expect(AccountState.titleCount(for: .system(.done), total: 48_213) == nil)
        let label = MailLocation.label(GmailLabelID("Label_12"))
        #expect(AccountState.titleCount(for: label, total: 12) == "12")
        #expect(AccountState.titleCount(for: label, total: 999) == "999")
        #expect(AccountState.titleCount(for: label, total: 1_000) == "999+")
        #expect(AccountState.titleCount(for: label, total: 0) == nil)
        #expect(AccountState.titleCount(for: .system(.sent), total: nil) == nil)
    }
}
