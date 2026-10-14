import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct OtherTabNewsletterRowsTests {
    private static let oldBundleSwitch = AppSettingKey(name: "inbox.bundle_newsletters", defaultValue: true)
    private static let newsletterQuery = "in:inbox (\(SplitPresets.newsletters.ruleText))"

    private func firstWindow(_ store: FakeMailStore, _ location: MailLocation, account: AccountID) async throws
        -> [ThreadKey] {
        for try await window in store.threadWindow(location, account: account, limit: 2_000) {
            return window.rows.map(\.id)
        }
        return []
    }

    @Test func newslettersStayIndividualRowsOnRealMailWithTheOldSwitchStoredOn() async throws {
        let store = FakeMailStore(corpus: .rich(threadCount: 400, now: fixedNow), options: .init(remoteAck: .immediate))
        try await store.set(Self.oldBundleSwitch, true)
        let env = AppEnvironment(data: store, commands: store, accounts: store, settings: store, isFake: false,
                                 onboardingProgress: InMemoryOnboardingProgress(), keymapStore: InMemoryKeymapStore())
        let router = env.router
        router.start()
        await eventually { router.accounts.count == 2 && router.list?.state == .loaded }
        #expect(router.perform(.switchToAccount(2)))
        let personal = try #require(router.active?.id)
        router.go(to: .splitOther)
        await eventually { router.list?.location == .splitOther && router.list?.state == .loaded }
        let list = try #require(router.list)

        let other = try await firstWindow(store, .splitOther, account: personal)
        let newsletters = Set(try await firstWindow(store, .search(Self.newsletterQuery), account: personal))
            .intersection(other)
        try #require(newsletters.count >= 5, "the Other tab holds several newsletters")
        await eventually { list.rows.map(\.id) == other }
        #expect(newsletters.allSatisfy { list.index(of: $0) != nil })
        #expect(list.rows.allSatisfy { $0.id.rowID > 0 }, "no made-up row stands for others")
        #expect(list.totalCount == other.count)

        let first = try #require(list.rows.first { newsletters.contains($0.id) }?.id)
        list.setCursor(first)
        #expect(router.actionContext().selection == [first])
        #expect(router.actionContext().focusedThread == first)
        #expect(try await store.get(Self.oldBundleSwitch))
    }
}
