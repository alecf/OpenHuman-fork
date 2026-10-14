import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct WaitingLocationTests {
    @Test func goToWaitingIsGWAndAPaletteEntry() {
        let descriptor = ActionCatalog.descriptor(.goWaiting)
        #expect(descriptor?.title == "Go to Waiting")
        #expect(descriptor?.defaultBindings.first == .sequence("g", "w"))
        let others = ActionCatalog.all.filter { $0.id != .goWaiting && $0.defaultBindings.contains(.sequence("g", "w")) }
        #expect(others.isEmpty)
        #expect(MailLocation.system(.waiting).sortsAscending)
    }

    @Test func goWaitingOpensTheWaitingList() async throws {
        let f = ActionFixture(corpus: .rich(threadCount: 40, now: fixedNow))
        await f.loaded()
        #expect(f.registry.availability(.goWaiting, host: f.router).isEnabled)
        #expect(await f.run(.goWaiting))
        #expect(f.router.location == .system(.waiting))
        #expect(f.router.active?.title(for: .system(.waiting)) == "Waiting")
        let state = try #require(f.router.active)
        #expect(state.sidebarItems.contains { $0.location == .system(.waiting) && $0.symbol == "hourglass" })
        await eventually { f.router.list?.state == .loaded }
        let dates = f.router.list?.rows.map(\.sortAt) ?? []
        #expect(dates == dates.sorted(), "oldest first")
    }

    @Test func theEmptyWaitingListSaysWhatItHolds() {
        let state = ThreadListEmptyState.make(location: .system(.waiting), locationTitle: "Waiting", state: .loaded,
                                              hasRows: false, loadingShown: false, connectivity: nil, day: 0)
        #expect(state?.title == "Nothing waiting for a reply.")
    }
}
