import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private struct TwoAccountStatusSource: MailDataSource {
    let base = FakeMailStore(corpus: .make(threadCount: 3, now: fixedNow))
    let states: [AccountID: ConnectivityState]
    let lines: [AccountID: String]

    func accounts() -> AsyncThrowingStream<[Account], Error> { base.accounts() }
    func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        base.threadWindow(location, account: account, limit: limit)
    }
    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> { base.threadDetail(key) }
    func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> { base.body(key) }
    func connectivity() -> AsyncStream<[AccountID: ConnectivityState]> {
        let states = self.states
        return AsyncStream { continuation in
            continuation.yield(states)
            continuation.finish()
        }
    }
    func syncProgress() -> AsyncStream<[AccountID: String]> {
        let lines = self.lines
        return AsyncStream { continuation in
            continuation.yield(lines)
            continuation.finish()
        }
    }
}

@MainActor
@Suite struct AccountStatusTests {
    let work = AccountID(1)
    let personal = AccountID(2)
    let synced = fixedNow.addingTimeInterval(-180)

    @Test func theSyncLineFollowsTheActiveAccount() async {
        let status = StatusModel(data: TwoAccountStatusSource(
            states: [work: .online(syncing: false, lastSyncAt: synced), personal: .offline(since: nil)], lines: [:]))
        await status.run()
        #expect(status.connectivity.count == 2, "every account's state, not only the opened one's")
        #expect(status.shownSync?.account == work, "no active account: the first by id")
        #expect(status.syncText(now: fixedNow) == "Synced 3 min ago")
        status.activeAccount = personal
        #expect(status.shownSync?.account == personal)
        #expect(status.syncText(now: fixedNow) == "Offline. Retrying.")
        status.activeAccount = AccountID(9)
        #expect(status.shownSync?.account == work, "an account the source has no state for falls back to the first")
    }

    @Test func theBackfillLineAndTheFailureCodeAreTheActiveAccounts() async {
        let status = StatusModel(data: TwoAccountStatusSource(
            states: [work: .syncFailing(code: "server_503", failures: 2, lastSyncAt: nil),
                     personal: .online(syncing: false, lastSyncAt: synced)],
            lines: [personal: "Syncing 1,240 of 4,707"]))
        await status.run()
        await eventually { !status.progress.isEmpty }
        status.activeAccount = work
        #expect(status.syncFailureCode == "server_503")
        #expect(status.syncText(now: fixedNow) == "Gmail is having trouble. Retrying.")
        status.activeAccount = personal
        #expect(status.syncFailureCode == nil, "the other account's failure is not this line's")
        #expect(status.syncText(now: fixedNow) == "Syncing 1,240 of 4,707", "the second account's own backfill line")
    }

    @Test func switchingAccountsMovesTheStatusArea() async throws {
        let env = AppEnvironment.fake(corpus: .rich(threadCount: 40, now: fixedNow))
        let router = env.router
        router.start()
        await eventually { router.accounts.count == 2 && router.list?.state == .loaded }
        let first = try #require(router.activeAccountID)
        #expect(env.status.activeAccount == first)
        #expect(router.switchAccount(position: 2))
        #expect(env.status.activeAccount == router.accounts[1].id)
        #expect(env.status.activeAccount != first)
    }

    @Test func theSwitcherNumberIsCappedAndHiddenAtZero() {
        #expect(AccountState.switcherBadge(0) == nil)
        #expect(AccountState.switcherBadge(-1) == nil)
        #expect(AccountState.switcherBadge(1) == "1")
        #expect(AccountState.switcherBadge(99) == "99")
        #expect(AccountState.switcherBadge(100) == "99+")
    }

    @Test func theSwitcherCountsImportantUnreadMail() async throws {
        let env = AppEnvironment.fake(corpus: .rich(threadCount: 40, now: fixedNow))
        let router = env.router
        router.start()
        await eventually { router.accounts.count == 2 && router.accounts.allSatisfy { $0.counts != nil } }
        for state in router.accounts {
            let counts = try #require(state.counts)
            #expect(state.badgeCount(.important) == (counts.importantUnread ?? state.firstTabUnread),
                    "the Dock badge's counter for that account")
        }
    }
}
