import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct ResyncTests {
    @Test func expiredHistoryTriggersAFullResyncThatRepairsTheInbox() async throws {
        let h = try SyncHarness()
        let threads = await h.gmail.seedInbox(count: 8)
        let (reply, _) = await h.gmail.deliver(subject: "Re", threadID: threads[6])
        try await h.syncer.sync(reason: "launch")
        #expect(try h.inbox().count == 8 && (try h.status()).generation == 1)

        await h.gmail.simulateWebArchive(threadID: threads[0])
        let gone = await h.gmail.messageIDs(inThread: threads[1])[0]
        await h.gmail.deleteMessagePermanently(gone)
        await h.gmail.deleteMessagePermanently(reply)
        let (_, fresh) = await h.gmail.deliver(subject: "During the gap")
        await h.gmail.expireAllHistory()
        await h.gmail.resetAccounting()

        let report = try await h.syncer.sync(reason: "launch")

        #expect(report.kind == "full_resync")
        let status = try h.status()
        #expect(status.phase == .inboxReady && status.generation == 2 && status.consecutiveFailures == 0)
        #expect(status.historyID == (await h.gmail.currentHistoryID))
        let historyCalls = await h.gmail.callCount(.listHistory), listCalls = await h.gmail.callCount(.listThreads)
        #expect(historyCalls == 1 && listCalls == 1)
        #expect(await h.gmail.callCount(.getThread) == 9)
        let inbox = try h.inbox()
        #expect(inbox == (try await h.serverInbox()))
        #expect(inbox.first == fresh && !inbox.contains(threads[0]) && !inbox.contains(threads[1]))
        #expect(try h.message(gone) == nil && (try h.message(reply)) == nil)
        #expect(try h.thread(threads[6])?.messages.count == 1)
        let log = try h.store.syncLog(account: h.account, limit: 5)
        #expect(log.first?.kind == "full_resync" && log.first?.outcome == "ok")

        await h.gmail.deliver(subject: "After")
        let next = try await h.syncer.sync(reason: "poll")
        #expect(next.kind == "incremental" && next.added == 1)
    }

    @Test func anInterruptedResyncStartsOverWithANewGeneration() async throws {
        let h = try SyncHarness()
        await h.gmail.seedInbox(count: 3)
        try await h.syncer.sync(reason: "launch")
        await h.gmail.expireAllHistory()
        await h.gmail.failNext(.listThreads, with: .transport(.notConnected))
        await #expect(throws: GmailError.transport(.notConnected)) { try await h.syncer.sync(reason: "poll") }
        var status = try h.status()
        #expect(status.phase == .resyncRequired && status.generation == 2 && status.consecutiveFailures == 1)
        try await h.syncer.sync(reason: "poll")
        status = try h.status()
        #expect(status.phase == .inboxReady && status.generation == 3 && status.consecutiveFailures == 0)
        #expect(try h.inbox() == (try await h.serverInbox()))
    }

    @Test func afterAResyncTheWalkSweepsWhatGmailNoLongerHas() async throws {
        let h = try SyncHarness(settings: backfillSettings(pageSize: 100))
        let seeded = await h.gmail.seedMailbox(count: 300, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        #expect(await h.syncer.runBackfill() == .complete)
        let keep = try #require(try h.fullInbox().last)
        let receipt = try h.store.apply(.archive([keep.ref]), origin: .app)

        let lost = try #require(await h.gmail.messageIDs(inThread: seeded.threads[10]).first)
        #expect(try h.message(lost) != nil)
        await h.gmail.deleteMessagePermanently(lost)
        await h.gmail.expireAllHistory()

        let report = try await h.syncer.sync(reason: "launch")
        #expect(try report.kind == "full_resync" && h.status().generation == 2)
        #expect(try h.message(lost) != nil)
        #expect(await h.syncer.runBackfill() == .complete)
        let status = try h.status()
        #expect(status.backfillComplete && status.phase == .incremental && status.generation == 2)
        #expect(try h.message(lost) == nil)
        let serverMessages = try await serverMessageIDs(h.gmail)
        #expect(try h.localMessages(among: serverMessages) == serverMessages)
        #expect(try h.store.sweepGeneration(account: h.account, olderThan: 2, newerThan: nil) == 0)
        let pending = try h.store.operations(account: h.account, statuses: [.pending], limit: 10)
        #expect(Set(pending.map(\.id)) == Set(receipt.operationIDs) && !receipt.operationIDs.isEmpty)
        #expect(try !h.fullInbox().contains { $0.ref == keep.ref })
        let log = try h.store.syncLog(account: h.account, limit: 10)
        #expect(log.contains { $0.kind == "backfill" && $0.detail == "all_mail_resync" && $0.deleted >= 1 })
    }

    @Test func aHistory404DuringTheWalkRestartsTheBackfillInTheNewGeneration() async throws {
        let h = try SyncHarness(settings: backfillSettings(pageSize: 100), recording: true)
        let recorder = try #require(h.recorder)
        let seeded = await h.gmail.seedMailbox(count: 300, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        let syncer = h.syncer, gmail = h.gmail
        let lost = try #require(await gmail.messageIDs(inThread: seeded.threads[10]).first)
        recorder.setHook { call, n in
            guard call.method == .listMessages, n == 2 else { return }
            await gmail.deleteMessagePermanently(lost)
            await gmail.expireAllHistory()
            _ = try? await syncer.sync(reason: "poll")
        }
        #expect(await h.syncer.runBackfill() == .cancelled)
        #expect(try h.status().generation == 2 && h.status().phase == .inboxReady)
        recorder.setHook(nil)
        #expect(await h.syncer.runBackfill() == .complete)
        let status = try h.status()
        #expect(status.backfillComplete && status.generation == 2)
        #expect(try h.message(lost) == nil)
        let serverMessages = try await serverMessageIDs(h.gmail)
        #expect(try h.localMessages(among: serverMessages) == serverMessages)
        #expect(Set(try h.fullInbox().map(\.ref.gmailThreadID.rawValue)) == Set(try await serverThreads(h.gmail, label: "INBOX")))
    }

    @Test func messagesUpsertedByTheResyncCarryTheNewGeneration() async throws {
        let h = try SyncHarness()
        await h.gmail.seedInbox(count: 2)
        try await h.syncer.sync(reason: "launch")
        await h.gmail.expireAllHistory()
        try await h.syncer.sync(reason: "poll")
        #expect(try h.store.sweepGeneration(account: h.account, olderThan: 2, newerThan: nil) == 0)
        #expect(try h.inbox().count == 2)
    }
}
