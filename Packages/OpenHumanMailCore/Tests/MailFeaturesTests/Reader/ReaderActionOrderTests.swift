import Foundation
import MailActions
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct ReaderActionOrderTests {
    private func context(location: MailLocation) -> ActionContext {
        let thread = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1"))
        var c = ActionContext(accountCount: 1, location: location)
        c.scope = .reader
        c.selection = [thread]
        c.focusedThread = thread
        return c
    }

    @Test func offeredActionsFollowCatalogOrder() {
        let catalogIDs = ActionCatalog.all.map(\.id)
        let c = context(location: .system(.inbox))
        let offered = ReaderActions.offeredThreadActions(registry: nil, host: nil, context: c).map(\.id)
        #expect(!offered.isEmpty)
        #expect(offered == catalogIDs.filter { offered.contains($0) })
    }

    @Test func theStripHoldsThePrimaryFiveAndTheMenuTheRest() {
        let c = context(location: .system(.inbox))
        let offered = ReaderActions.offeredThreadActions(registry: nil, host: nil, context: c)
        let (primary, more) = ReaderActions.split(offered)
        #expect(primary.map(\.id) == ReaderActions.primaryThreadActionIDs.filter { id in offered.contains { $0.id == id } })
        #expect(primary.map(\.id).starts(with: [.markDone]))
        #expect(more.map(\.id) == offered.map(\.id).filter { !ReaderActions.primaryThreadActionIDs.contains($0) })
        #expect(Set(primary.map(\.id)).union(more.map(\.id)) == Set(offered.map(\.id)))
        #expect(primary.count + more.count == offered.count)
        #expect(!more.isEmpty, "Move, Star, Unread, Spam… are in the menu")
        let (noTrash, _) = ReaderActions.split(offered.filter { $0.id != .trash })
        #expect(!noTrash.contains { $0.id == .trash })
    }

    @Test func orderIsIdenticalOver200FreshRegistries() {
        let c = context(location: .system(.inbox))
        let first = ReaderActions.offeredThreadActions(registry: nil, host: nil, context: c).map(\.id.rawValue)
        #expect(!first.isEmpty)
        let firstThreadActions = ReaderActions.threadActions.map(\.id.rawValue)
        for _ in 0..<200 {
            let registry = ActionRegistry()
            #expect(ReaderActions.offeredThreadActions(registry: nil, host: nil, context: c).map(\.id.rawValue) == first)
            #expect(ReaderActions.threadActions.map(\.id.rawValue) == firstThreadActions)
            let inRegistry = registry.descriptors(in: .thread).map(\.id.rawValue)
            #expect(inRegistry == ActionCatalog.descriptors(in: .thread).map(\.id.rawValue).filter { inRegistry.contains($0) })
            #expect(ReaderActions.offeredThreadActions(registry: registry, host: nil, context: c).map(\.id.rawValue)
                    == firstThreadActions.filter { id in
                        ReaderActions.offeredThreadActions(registry: registry, host: nil, context: c).contains { $0.id.rawValue == id }
                    })
        }
    }
}
