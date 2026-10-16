import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized)
struct DockBadgeTests {
    private func unreadImportant(_ f: SystemFixture) async throws -> Int {
        try #require(await first(f.store.counts(f.account))).importantUnread ?? -1
    }

    @Test func textRules() {
        #expect(DockBadgeModel.text(for: 0) == "")
        #expect(DockBadgeModel.text(for: -3) == "")
        #expect(DockBadgeModel.text(for: 7) == "7")
        #expect(DockBadgeModel.text(for: 999) == "999")
        #expect(DockBadgeModel.text(for: 1000) == "999+")
    }

    @Test func followsImportantUnreadAcrossAccountsAndClearsAtZero() async throws {
        let f = SystemFixture(corpus: .small)
        f.env.system.startDockBadge()
        let model = try #require(f.env.system.dockBadge)
        await eventually(timeout: .seconds(15)) { model.total > 0 }
        var expected = 0
        for account in FakeCorpus.small.accounts.map(\.id) { expected += try await first(f.store.counts(account))?.importantUnread ?? 0 }
        #expect(model.total == expected)
        await eventually(timeout: .seconds(15)) { f.dock.label == DockBadgeModel.text(for: expected) }
        let before = f.dock.label
        f.store.deliverMessage(account: f.account, from: EmailAddress(name: "A", email: "a@x.example"), subject: "Important", important: true)
        f.store.deliverMessage(account: f.account, from: EmailAddress(name: "B", email: "b@x.example"), subject: "Promo")
        await eventually(timeout: .seconds(15)) { f.dock.label != before }
        #expect(f.dock.label == DockBadgeModel.text(for: expected + 1), "a thread that is not important never raises the badge")
    }

    @Test func clearsWhenNothingIsImportantAndUnread() async throws {
        let f = SystemFixture(corpus: .make(threadCount: 4, now: fixedNow))
        f.env.system.startDockBadge()
        let model = try #require(f.env.system.dockBadge)
        await eventually(timeout: .seconds(15)) { model.label == DockBadgeModel.text(for: model.total) }
        let rows = try #require(await first(f.store.threadWindow(.system(.inbox), account: f.account, limit: 50))).rows
        _ = try await f.store.apply(.markRead(rows.filter { $0.isUnread && $0.isImportant }.map(\.id)))
        await eventually(timeout: .seconds(15)) { model.total == 0 }
        await eventually(timeout: .seconds(15)) { f.dock.label == "" }
    }

    @Test func settingPicksImportantInboxOrOff() async throws {
        let f = SystemFixture(corpus: .make(threadCount: 30, now: fixedNow))
        f.env.system.startDockBadge()
        let model = try #require(f.env.system.dockBadge)
        await eventually(timeout: .seconds(15)) { model.total > 0 }
        let counts = try #require(await first(f.store.counts(f.account)))
        f.env.system.preferences.dockBadge = .inbox
        await eventually(timeout: .seconds(15)) { model.total == counts.inboxUnread }
        f.env.system.preferences.dockBadge = .off
        await eventually(timeout: .seconds(15)) { f.dock.label == "" && model.total == 0 }
        f.env.system.preferences.dockBadge = .important
        await eventually(timeout: .seconds(15)) { model.total == counts.importantUnread ?? 0 }
    }

    @Test func updatesAreCoalescedToOnePerInterval() async throws {
        let f = SystemFixture(corpus: .make(threadCount: 4, now: fixedNow))
        let model = DockBadgeModel(data: f.store, badge: f.dock, preferences: f.env.system.preferences, interval: .seconds(30))
        model.start()
        await eventually(timeout: .seconds(15)) { f.dock.history.count >= 1 || model.total == 0 }
        let baseline = f.dock.history.count
        for index in 0..<5 {
            f.store.deliverMessage(account: f.account, from: EmailAddress(name: "A", email: "a\(index)@x.example"),
                                   subject: "Burst \(index)", important: true)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.dock.history.count - baseline <= 1, "within one interval at most the first change is applied")
        model.stop()
        #expect(f.dock.label == "", "stopping clears the tile")
    }

    @Test func moduleOffLeavesTheTileAlone() {
        let f = SystemFixture(flags: FeatureFlags().with(.dockBadge, false))
        f.env.runLaunchTasks()
        #expect(f.env.system.dockBadge == nil)
        #expect(f.dock.history.isEmpty)
    }
}
