import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
final class FocusFixture {
    let env: AppEnvironment
    let store: FakeMailStore
    let recorder: RecordingCommands
    let router: AppRouter
    let notifier = FakeSystemNotifier(authorization: .authorized)
    let dock = FakeDockBadge()
    let menuBarItem = FakeMenuBarItem()
    var typing = false
    var current: FocusFilterState?

    static let work = AccountID(1)
    static let personal = AccountID(2)

    init(flags: FeatureFlags = FeatureFlags(), current: FocusFilterState? = nil) {
        self.current = current
        store = FakeMailStore(corpus: .rich(threadCount: 40, now: fixedNow),
                              options: .init(remoteAck: .immediate, now: { fixedNow }))
        recorder = RecordingCommands(store)
        env = AppEnvironment(data: store, commands: recorder, accounts: store, settings: store, isFake: true,
                             featureFlags: flags)
        router = env.router
        var platform = SystemPlatform(notifier: notifier, dock: dock, loginItem: FakeLoginItem(),
                                      urlOpener: FakeURLOpener(), menuBarItem: menuBarItem, isAppActive: { false })
        platform.isAuthorTyping = { [unowned self] in self.typing }
        platform.currentFocusFilter = { [unowned self] in self.current }
        env.installPlatform(platform)
        env.system.coalesce = .milliseconds(20)
        router.start()
    }

    var system: SystemCenter { env.system }
    var defaults: UserDefaults { env.system.preferences.defaults }

    func loaded() async {
        await eventually { router.accounts.count == 2 && router.list?.state == .loaded }
    }

    @discardableResult
    func startFocus() async throws -> FocusFilterModel {
        system.startFocusFilters()
        let focus = try #require(system.focus)
        focus.sleep = { _ in }
        await focus.waitForLaunch()
        return focus
    }

    func startNotifications() async throws -> NotificationService {
        system.startNotifications()
        let service = try #require(system.notifications)
        await eventually { service.hasBaseline(for: Self.work) && service.hasBaseline(for: Self.personal) }
        return service
    }

    func importantUnread(_ account: AccountID) async throws -> Int {
        try #require(try await first(store.counts(account))).importantUnread ?? 0
    }

    var toasts: [String] { env.notices.toasts.map(\.message) }
}

@MainActor
@Suite(.serialized) struct FocusFilterTests {
    private let marker = EmailAddress(name: "Zed Markerman", email: "zed@marker-sender.example")

    @Test func aFilterBringsItsFirstAccountForwardOnImportant() async throws {
        let f = FocusFixture()
        await f.loaded()
        let focus = try await f.startFocus()
        #expect(f.router.activeAccountID == FocusFixture.work)
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.personal], openOn: .important))
        #expect(f.router.activeAccountID == FocusFixture.personal)
        await eventually { f.router.active?.splitsLoaded == true && f.router.location == f.router.active?.firstTab }
        #expect(focus.active?.accounts == [FocusFixture.personal])
        #expect(f.env.status.focusLine == "Focus: Personal first")
        f.router.switchAccount(to: FocusFixture.work)
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.personal], openOn: .inbox))
        #expect(f.router.activeAccountID == FocusFixture.personal)
        #expect(f.recorder.calls.isEmpty, "a filter writes nothing")
    }

    @Test func aBusyAuthorGetsAToastAndStaysPut() async throws {
        let f = FocusFixture()
        await f.loaded()
        try await f.startFocus()
        f.typing = true
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.personal]))
        #expect(f.router.activeAccountID == FocusFixture.work)
        #expect(f.toasts.contains("A Focus put Personal first. ⌃2 shows Personal."))
        f.typing = false
        f.router.composerContext = { ActionContext(scope: .composer) }
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.personal], openOn: .inbox))
        #expect(f.router.activeAccountID == FocusFixture.work)
    }

    @Test func theSameFilterAgainMovesNothingAndARelaunchKeepsThePlace() async throws {
        let f = FocusFixture()
        await f.loaded()
        try await f.startFocus()
        let state = FocusFilterState(accounts: [FocusFixture.personal])
        await f.system.applyFocusFilter(state)
        #expect(f.router.activeAccountID == FocusFixture.personal)
        f.router.switchAccount(to: FocusFixture.work)
        await f.system.applyFocusFilter(state)
        #expect(f.router.activeAccountID == FocusFixture.work, "the same filter again moves nothing")
        f.current = state
        let relaunched = FocusFilterModel(environment: f.env, platform: f.system.platform, defaults: f.defaults)
        relaunched.sleep = { _ in }
        relaunched.start()
        await relaunched.waitForLaunch()
        #expect(f.router.activeAccountID == FocusFixture.work)
        #expect(relaunched.active == state)
        f.current = FocusFilterState(accounts: [FocusFixture.personal], openOn: .stay)
        let changed = FocusFilterModel(environment: f.env, platform: f.system.platform, defaults: f.defaults)
        changed.sleep = { _ in }
        changed.start()
        await changed.waitForLaunch()
        #expect(f.router.activeAccountID == FocusFixture.personal)
    }

    @Test func unknownAccountsDropAndNoneLeftIsNoFilter() async throws {
        let f = FocusFixture()
        await f.loaded()
        let focus = try await f.startFocus()
        await f.system.applyFocusFilter(FocusFilterState(accounts: [AccountID(99)]))
        #expect(focus.active == nil)
        #expect(f.router.activeAccountID == FocusFixture.work)
        await f.system.applyFocusFilter(FocusFilterState(accounts: [AccountID(99), FocusFixture.personal, FocusFixture.personal]))
        #expect(focus.active?.accounts == [FocusFixture.personal])
        #expect(FocusFilterState(accounts: []).keeping([FocusFixture.work]) == nil)
    }

    @Test func withTheModuleOffNothingHappensAndNothingIsStored() async throws {
        let f = FocusFixture(flags: FeatureFlags().with(.focusFilters, false))
        await f.loaded()
        #expect(!f.env.modules.modules.contains(.focusFilters))
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.personal]))
        #expect(f.router.activeAccountID == FocusFixture.work)
        #expect(f.defaults.object(forKey: FocusFilterModel.currentKey) == nil)
        let settings = FocusFilterSettingsModel(system: f.system)
        #expect(!settings.isOn && settings.status.hasPrefix("Off."))
        await settings.setOn(true)
        #expect(settings.isOn && f.system.preferences.focusFiltersEnabled)
        await f.system.focus?.waitForLaunch()
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.personal], holdOtherNotifications: true))
        #expect(settings.status == "A Focus filter is on: Personal first, opens on Important. Work notifications held.")
        await settings.setOn(false)
        #expect(f.system.focus == nil && f.defaults.object(forKey: FocusFilterModel.currentKey) == nil)
        #expect(f.env.status.focusLine == nil)
    }

    @Test func heldMailPostsNothingThenOneCountsOnlySummary() async throws {
        let f = FocusFixture()
        await f.loaded()
        let focus = try await f.startFocus()
        let service = try await f.startNotifications()
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.work], holdOtherNotifications: true))
        #expect(f.env.status.focusLine == "Focus: Work first · Personal notifications held")
        #expect(focus.holdsNewMail(for: FocusFixture.personal) && !focus.holdsNewMail(for: FocusFixture.work))
        let firstKey = f.store.deliverMessage(account: FocusFixture.personal, from: marker, subject: "MARKERSUBJECT one",
                                              important: true)
        f.store.deliverMessage(account: FocusFixture.personal, from: marker, subject: "MARKERSUBJECT two", important: true)
        await eventually { focus.held.count == 2 }
        await service.flushNow()
        #expect(f.notifier.delivered.isEmpty, "nothing posts during the Focus")
        let relaunched = FocusFilterModel(environment: f.env, platform: f.system.platform, defaults: f.defaults)
        #expect(relaunched.held.count == 2)
        let read = try #require(focus.held.first { $0.account == firstKey.account })
        _ = try await f.store.apply(.markRead([read]))
        f.system.preferences.hidePreviews = false
        await f.system.applyFocusFilter(nil)
        await eventually { f.notifier.delivered.count == 1 }
        let summary = try #require(f.notifier.delivered.first)
        #expect(summary.title == NotificationService.focusSummaryTitle)
        #expect(summary.body == "1 important conversation arrived in Personal.")
        for text in [summary.title, summary.body] {
            #expect(!text.contains("MARKER") && !text.contains("Zed") && !text.contains("marker-sender"))
        }
        #expect(focus.held.isEmpty && f.env.status.focusLine == nil)
        #expect(f.recorder.calls.isEmpty, "holding writes nothing")
    }

    @Test func theHeldListKeepsTheNewest500() async throws {
        let f = FocusFixture()
        await f.loaded()
        let focus = try await f.startFocus()
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.work], holdOtherNotifications: true))
        focus.hold((0..<510).map { ThreadKey(account: FocusFixture.personal, rowID: Int64(10_000 + $0),
                                             gmailThreadID: GmailThreadID("held\($0)")) })
        #expect(focus.held.count == FocusFilterModel.maxHeld)
        #expect(focus.held.first?.rowID == 10_010, "the oldest go first")
    }

    @Test func ignoreThisFocusReleasesAtOnceUntilTheFilterChanges() async throws {
        let f = FocusFixture()
        await f.loaded()
        let focus = try await f.startFocus()
        _ = try await f.startNotifications()
        let state = FocusFilterState(accounts: [FocusFixture.work], holdOtherNotifications: true)
        await f.system.applyFocusFilter(state)
        f.store.deliverMessage(account: FocusFixture.personal, from: marker, subject: "MARKERSUBJECT", important: true)
        await eventually { focus.held.count == 1 }
        let settings = FocusFilterSettingsModel(system: f.system)
        #expect(settings.canIgnore)
        await settings.ignoreThisFocus()
        #expect(focus.active == nil && !settings.canIgnore)
        await eventually { f.notifier.delivered.count == 1 }
        await f.system.applyFocusFilter(state)
        #expect(focus.active == nil, "the same Focus stays ignored")
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.personal]))
        #expect(focus.active?.accounts == [FocusFixture.personal], "a new filter ends Ignore")
    }

    @Test func theBadgeAndTheMenuBarCountOnlyTheFocusAccountsOnRequest() async throws {
        let f = FocusFixture()
        await f.loaded()
        try await f.startFocus()
        f.system.startDockBadge()
        f.system.setMenuBar(enabled: true)
        let work = try await f.importantUnread(FocusFixture.work)
        let personal = try await f.importantUnread(FocusFixture.personal)
        let badge = try #require(f.system.dockBadge)
        let menuBar = try #require(f.system.menuBar)
        await eventually { badge.total == work + personal && menuBar.total == work + personal }
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.work]))
        #expect(badge.total == work + personal, "without the opt-in every account counts")
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.work], badgeOnlyTheseAccounts: true))
        #expect(badge.total == work && menuBar.total == work)
        f.system.preferences.dockBadge = .off
        #expect(badge.total == 0, "Off stays off")
        await f.system.applyFocusFilter(nil)
        #expect(menuBar.total == work + personal)
    }

    @Test func aFilterNeverHidesMailOrTouchesTheAuthorsSwitches() async throws {
        let f = FocusFixture()
        await f.loaded()
        try await f.startFocus()
        let locations: [MailLocation] = [.system(.inbox), .system(.allMail), .system(.starred), .splitOther]
        var before: [String: [ThreadKey]] = [:]
        for account in [FocusFixture.work, FocusFixture.personal] {
            for location in locations {
                let rows = try #require(try await first(f.store.threadWindow(location, account: account, limit: 200))).rows
                before["\(account.rawValue)\(location)"] = rows.map(\.id)
            }
        }
        let switches = [FocusFixture.work, FocusFixture.personal].map { f.system.preferences.newMailEnabled($0) }
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.personal], holdOtherNotifications: true,
                                                         badgeOnlyTheseAccounts: true))
        for account in [FocusFixture.work, FocusFixture.personal] {
            for location in locations {
                let rows = try #require(try await first(f.store.threadWindow(location, account: account, limit: 200))).rows
                #expect(rows.map(\.id) == before["\(account.rawValue)\(location)"], "\(account) \(location)")
            }
        }
        #expect([FocusFixture.work, FocusFixture.personal].map { f.system.preferences.newMailEnabled($0) } == switches)
        #expect(f.defaults.object(forKey: SystemPreferences.newMailKey(FocusFixture.work)) == nil)
        #expect(f.router.accounts.count == 2, "every account stays in the switcher")
        #expect(f.recorder.calls.isEmpty)
    }

    @Test func storageHoldsIdsAndEnumsOnly() async throws {
        let f = FocusFixture()
        await f.loaded()
        let focus = try await f.startFocus()
        _ = try await f.startNotifications()
        await f.system.applyFocusFilter(FocusFilterState(accounts: [FocusFixture.work], holdOtherNotifications: true))
        f.store.deliverMessage(account: FocusFixture.personal, from: marker, subject: "MARKERSUBJECT", important: true)
        await eventually { focus.held.count == 1 }
        for key in [FocusFilterModel.currentKey, FocusFilterModel.heldKey] {
            let data = try #require(f.defaults.data(forKey: key))
            let text = String(decoding: data, as: UTF8.self)
            for leak in ["MARKER", "Zed", "marker-sender", "@", "Work", "Personal"] {
                #expect(!text.contains(leak), "\(key) holds \(leak)")
            }
        }
        #expect(FocusFilterState(accounts: [FocusFixture.work, FocusFixture.personal], openOn: .inbox,
                                 holdOtherNotifications: true).identity == "accounts=1,2;open=inbox;hold=1;badge=0")
    }
}
