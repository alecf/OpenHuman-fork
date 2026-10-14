import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct EventsSplitTests {
    private static let google = "calendar-notification@google.com"

    private func split(_ store: MailStore, _ account: AccountID, _ name: String) throws -> SplitItem {
        try #require(try store.splits(account: account).first { $0.name == name })
    }

    private func otherTotal(_ store: MailStore, _ account: AccountID) throws -> Int {
        try #require(try store.label(account: account, key: "oh:split:other")).totalThreads
    }

    private func invite(_ id: String, labels: [String] = ["INBOX"], minutes: Int = 0) -> MessageUpsert {
        .fixture(id, minutes: minutes, labels: labels, from: "sam@example.org", subject: "Design review",
                 body: MessageBodyUpsert(text: "x", hasCalendarInvite: true, decodeWarnings: [], searchText: "x"))
    }

    @Test func aMetadataOnlyGoogleInvitationLandsInTheSeededCalendarSplit() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.upsertMessages([
            .fixture("inv", from: Self.google, fromName: "Sam Rivera (via Google Calendar)",
                     subject: "Invitation: Design review @ Mon Oct 19, 2026 10am - 11am (UTC) (me@example.com)"),
            .fixture("plain", subject: "Quarterly numbers"),
        ], account: account, generation: 1)
        #expect(try store.message(account: account, gmailMessageID: GmailMessageID("inv"))?.hasCalendarInvite == false)
        #expect(try split(store, account, "Calendar").totalThreads == 1)
        #expect(try otherTotal(store, account) == 1, "the ordinary message stays in Other")
    }

    @Test func everyKindOfEventMailMatchesIsEvent() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        try store.upsertLabels([LabelUpsert(gmailLabelID: GmailLabelID("Label_meet"), name: "OpenHuman/Meeting", type: "user",
                                            labelListVisibility: "labelHide", messageListVisibility: "hide")],
                               account: account, removeMissing: false)
        _ = try store.upsertMessages([
            invite("part"),
            .fixture("gcal", from: Self.google, subject: "Accepted: Design review"),
            .fixture("prefix", from: "lee@example.net", subject: "Updated invitation: Retro"),
            .fixture("fwd", from: "lee@example.net", subject: "Fwd: Invitation: Offsite"),
            .fixture("luma", from: "hello@lu.ma", subject: "Your ticket"),
            .fixture("brite", from: "orders@mail.eventbrite.com", subject: "Order confirmed"),
            .fixture("phrase", from: "team@example.com", subject: "You are invited: demo night"),
            .fixture("label", labels: ["INBOX", "Label_meet"], subject: "Sync up"),
            .fixture("plain1", subject: "Quarterly numbers"),
            .fixture("plain2", from: "jobs@example.org", subject: "Accepted: your application"),
        ], account: account, generation: 1)
        #expect(try split(store, account, "Calendar").totalThreads == 8)
        #expect(try otherTotal(store, account) == 2)
        let hits = try store.search(try store.parseSearch("is:event"), accounts: [account], after: nil, limit: 50).hits
        #expect(Set(hits.map(\.thread.ref.gmailThreadID.rawValue))
                == ["t-part", "t-gcal", "t-prefix", "t-fwd", "t-luma", "t-brite", "t-phrase", "t-label"])
        let none = try store.search(try store.parseSearch("is:event subject:quarterly"), accounts: [account], after: nil,
                                    limit: 50).hits
        #expect(none.isEmpty)
    }

    @Test func anEventsOnlySplitListsImportantEventsAndAnAndRuleDoesNot() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        let calendar = try split(store, account, "Calendar")
        _ = try store.upsertSplit(account: account, id: calendar.id, name: "Calendar", ruleText: "has:invite", position: nil,
                                  enabled: true)
        _ = try store.upsertMessages([invite("plain"), invite("vip", labels: ["INBOX", "IMPORTANT"], minutes: 1)],
                                     account: account, generation: 1)
        #expect(try split(store, account, "Calendar").totalThreads == 2)
        #expect(try split(store, account, "Important").totalThreads == 1)

        _ = try store.upsertSplit(account: account, id: calendar.id, name: "Calendar", ruleText: "has:invite -is:important",
                                  position: nil, enabled: true)
        #expect(try split(store, account, "Calendar").totalThreads == 1, "the AND rule takes only the plain invite")
        #expect(try split(store, account, "Important").totalThreads == 1)
    }

    @Test func inviteCheckCandidatesAreHeaderMatchesWithoutABody() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.upsertMessages([
            .fixture("old-inbox", minutes: 0, from: Self.google, subject: "Invitation: A"),
            .fixture("new-inbox", minutes: 5, from: "lee@example.net", subject: "Canceled event: B"),
            .fixture("archived", minutes: 9, labels: [], from: "lee@example.net", subject: "Invitation: C"),
            .fixture("trashed", minutes: 8, labels: ["TRASH"], from: Self.google, subject: "Invitation: D"),
            .fixture("stored", minutes: 7, from: Self.google, subject: "Invitation: E", body: .fixture()),
            .fixture("platform", minutes: 6, from: "hello@lu.ma", subject: "Your ticket"),
            .fixture("phrase", minutes: 6, subject: "RSVP by Friday"),
            .fixture("plain", minutes: 6, subject: "Quarterly numbers"),
        ], account: account, generation: 1)
        #expect(try store.messagesNeedingInviteCheck(account: account, limit: 10).map(\.rawValue)
                == ["new-inbox", "old-inbox", "archived"])
        #expect(try store.messagesNeedingInviteCheck(account: account, limit: 1).map(\.rawValue) == ["new-inbox"])
        #expect(try store.messagesNeedingInviteCheck(account: account, limit: 0).isEmpty)
    }

    @Test func theInboxIsPlacedAgainOnceAfterAnUpgradeAndOnRescan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oh-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let options = StoreOptions(location: StoreLocation(directory: dir), processKind: .test, appVersion: "test",
                                   changeNotificationName: "oh.test.events.\(UUID().uuidString)")
        var store = try MailStore.open(options)
        let account = try store.addAccount(email: "me@example.com", displayName: "Me", scopes: ["gmail.readonly"])
        _ = try store.upsertMessages([invite("vip", labels: ["INBOX", "IMPORTANT"])], account: account, generation: 1)
        let calendarRid = try split(store, account, "Calendar").labelRowID.rawValue
        func calendarRows() throws -> Int {
            try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM thread_labels WHERE label_rid = ?",
                                              arguments: [calendarRid]) ?? 0 }
        }
        #expect(try calendarRows() == 1)
        try store.write { db in
            try db.execute(sql: "DELETE FROM thread_labels WHERE label_rid = ?", arguments: [calendarRid])
            try db.execute(sql: "DELETE FROM maintenance_tasks WHERE task = ?", arguments: [MailStore.placementTask])
        }
        #expect(try calendarRows() == 0)
        try store.close()
        store = try MailStore.open(options)
        #expect(try calendarRows() == 1, "placed again on open")

        try store.write { db in try db.execute(sql: "DELETE FROM thread_labels WHERE label_rid = ?", arguments: [calendarRid]) }
        try store.close()
        store = try MailStore.open(options)
        #expect(try calendarRows() == 0, "once per version only")
        try store.setSetting(.eventsRescanAt, 1_790_000_000_000, scope: .account(account))
        #expect(try calendarRows() == 1, "Re-scan for invites places the inbox again")
        try store.close()
    }
}
