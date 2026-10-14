import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct ReappearRaceTests {
    @Test func aHistoryPageListedBeforeTheLastArchiveLandsAfterItAndTheConversationStaysDone() async throws {
        let h = try await WriteHarness(threads: 2)
        let probe = ProbeGmail(h.gmail)
        let syncer = AccountSyncer(account: h.account, store: h.store, api: probe, clock: h.clock)
        let drainer = h.drainer(api: h.gmail)
        let thread = h.threads[0]

        let first = try h.store.apply(.archive([try h.ref(thread)]), origin: .app)
        await drainer.drainOnce()
        _ = try #require(try h.store.undo(first, origin: .app))
        await drainer.drainOnce()
        #expect(try h.inbox().contains(thread))

        let gate = probe.holdAnswer(.listHistory)
        let poll = Task { try await syncer.sync(reason: "poll") }
        try await eventually("history listed") { gate.reached }
        _ = try h.store.apply(.archive([try h.ref(thread)]), origin: .app)
        await drainer.drainOnce()
        #expect(!(await h.serverLabels(ofThread: thread)).contains("INBOX"))
        #expect(!(try h.inbox().contains(thread)))

        gate.open()
        _ = try await poll.value
        #expect(!(try h.inbox().contains(thread)), "the stale page brought the archived conversation back")

        _ = try await syncer.sync(reason: "poll")
        #expect(!(try h.inbox().contains(thread)))
        #expect(try h.ops([.succeeded]).count == 3 && h.ops([.pending, .inFlight, .failed]).isEmpty)
        let server = try await h.serverInbox()
        #expect(Set(try h.inbox()) == Set(server))
    }

    @Test func aResyncFetchAnsweredBeforeTheArchiveReachedGmailDoesNotUndoIt() async throws {
        let h = try await WriteHarness(threads: 2)
        let probe = ProbeGmail(h.gmail)
        let syncer = AccountSyncer(account: h.account, store: h.store, api: probe, clock: h.clock)
        let drainer = h.drainer(api: h.gmail)
        let thread = h.threads[0]

        await h.gmail.expireAllHistory()
        let gate = probe.holdAnswer(.getThread)
        let wake = Task { try await syncer.sync(reason: "wake") }
        try await eventually("inbox fetched") { gate.reached }
        _ = try h.store.apply(.archive([try h.ref(thread)]), origin: .app)
        await drainer.drainOnce()
        #expect(!(await h.serverLabels(ofThread: thread)).contains("INBOX"))

        gate.open()
        _ = try await wake.value
        #expect(!(try h.inbox().contains(thread)), "the resync's earlier read brought the archived conversation back")

        _ = try await syncer.sync(reason: "poll")
        #expect(!(try h.inbox().contains(thread)))
        let server = try await h.serverInbox()
        #expect(Set(try h.inbox()) == Set(server))
    }

    @Test func aChangeMadeOnAnotherDeviceAfterOursStillShows() async throws {
        let h = try await WriteHarness(threads: 2)
        let drainer = h.drainer(api: h.gmail)
        let thread = h.threads[0]
        _ = try h.store.apply(.archive([try h.ref(thread)]), origin: .app)
        await drainer.drainOnce()
        for id in await h.gmail.messageIDs(inThread: thread) {
            try await h.gmail.batchModifyMessages(ids: [id], add: ["INBOX"], remove: [])
        }
        _ = try await h.syncer.sync(reason: "poll")
        #expect(try h.inbox().contains(thread))
    }
}
