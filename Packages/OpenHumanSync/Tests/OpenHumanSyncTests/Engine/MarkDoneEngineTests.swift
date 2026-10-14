import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct MarkDoneEngineTests {
    @Test func performShowsAtOnceDrainsAndUndoRestores() async throws {
        let h = try await EngineHarness(stack: true)
        defer { h.cleanup() }
        let wire = try #require(h.wire)
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        #expect(await engine.drainer(for: h.account) != nil)
        let thread = h.threads[1]

        let receipt = try await engine.perform(.archive([try h.ref(thread)]), origin: .app)
        #expect(!(try h.inbox().contains(thread)))
        try await eventually("archive reached Gmail") { !(await h.serverLabels(ofThread: thread)).contains("INBOX") }
        try await eventually("op succeeded") { try h.store.operation(receipt.operationIDs[0])?.status == .succeeded }

        let redo = try #require(try await engine.undo(receipt))
        #expect(try h.inbox().contains(thread))
        try await eventually("undo reached Gmail") { (await h.serverLabels(ofThread: thread)).contains("INBOX") }
        #expect(redo.undo == .archive([try h.ref(thread)]))

        _ = try await engine.undo(redo)
        try await eventually("redo reached Gmail") { !(await h.serverLabels(ofThread: thread)).contains("INBOX") }
        #expect(wire.nonGETRequests.allSatisfy { $0.url.path() == "/gmail/v1/users/me/messages/batchModify" })
        _ = try await engine.syncNow(h.account, reason: "test")
        #expect(Set(try h.inbox()) == Set(h.threads).subtracting([thread]))
        await engine.stop()
    }

    @Test func archiveOfflineIsAppliedWhenTheNetworkComesBack() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        await h.gmail.failNext(.batchModify, with: .transport(.notConnected))
        let thread = h.threads[0]
        let receipt = try await engine.perform(.archive([try h.ref(thread)]), origin: .app)
        let op = receipt.operationIDs[0]
        try await eventually("released") {
            let item = try h.store.operation(op)
            return item?.status == .pending && item?.nextRetryAt == h.clock.now.addingTimeInterval(30)
        }
        #expect(try h.store.operation(op)?.attempts == 0)
        #expect(!(try h.inbox().contains(thread)))
        h.clock.advance(by: .seconds(30))
        try await eventually("applied after reconnect") { try h.store.operation(op)?.status == .succeeded }
        #expect(!(await h.serverLabels(ofThread: thread)).contains("INBOX"))
        _ = try await engine.syncNow(h.account, reason: "test")
        #expect(!(try h.inbox().contains(thread)))
        await engine.stop()
    }

    @Test func undoBeforeTheDrainerRunsCancelsLocally() async throws {
        let h = try await EngineHarness(stack: true)
        defer { h.cleanup() }
        let wire = try #require(h.wire)
        try await AccountSyncer(account: h.account, store: h.store, api: try h.factory.client(for: "me@example.com"),
                                clock: h.clock).sync(reason: "test")
        let engine = h.engine()
        let receipt = try await engine.perform(.archive([try h.ref(h.threads[0])]), origin: .app)
        let redo = try #require(try await engine.undo(receipt))
        #expect(redo.operationIDs.isEmpty)
        await engine.start()
        try await h.waitForSyncs(engine)
        let report = await engine.drainer(for: h.account)?.drainOnce()
        #expect(report?.claimed == 0)
        #expect(wire.nonGETRequests.isEmpty)
        #expect(Set(try h.inbox()) == Set(h.threads))
        await engine.stop()
    }

    @Test func startRequeuesWhatADeadOwnerLeftInFlight() async throws {
        let h = try await EngineHarness()
        try await AccountSyncer(account: h.account, store: h.store, api: h.gmail, clock: h.clock).sync(reason: "test")
        let receipt = try h.store.apply(.archive([try h.ref(h.threads[0])]), origin: .app)
        _ = try h.store.claimReadyOperations(account: h.account, now: h.clock.now, limit: 10, ownerID: "crashed-app")
        h.clock.advance(by: .seconds(1))
        let engine = h.engine()
        await engine.start()
        try await eventually("requeued and drained") {
            try h.store.operation(receipt.operationIDs[0])?.status == .succeeded
        }
        #expect(try h.store.operation(receipt.operationIDs[0])?.attempts == 1)
        await engine.stop()
    }
}
