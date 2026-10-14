import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct SendTests {
    @Test func sendQueuesTheUploadThenTheSendAfterTheUndoWindow() throws {
        let f = try MutationFixture()
        let id = try f.newDraft()
        let before = Date()
        let receipt = try f.store.send(id, undoWindow: .seconds(10), origin: .app)
        let upload = try f.op(try #require(receipt.upsertOperationID))
        let send = try f.op(receipt.sendOperationID)
        #expect(upload.payload == .upsertDraft(draftID: id, version: 1))
        #expect(send.payload == .sendDraft(draftID: id) && send.dependsOn == upload.id && send.coalesceKey == nil)
        #expect(abs(send.notBefore.timeIntervalSince(before.addingTimeInterval(10))) < 1)
        #expect(try receipt.sendAfter == send.notBefore && f.draftRow(id)["state"] as String == "sending")
        #expect(try f.claim().map(\.id) == [upload.id])
        try f.store.complete(upload.id, outcome: .draftSaved(gmailDraftID: GmailDraftID("r1"), gmailMessageID: GmailMessageID("dm1"),
                                                              version: 1))
        #expect(try f.claim().isEmpty)
        #expect(try f.claim(Date().addingTimeInterval(11)).map(\.id) == [send.id])
    }

    @Test func aCleanSyncedDraftSendsWithoutAnUpload() throws {
        let f = try MutationFixture()
        let id = try f.syncedDraft()
        let receipt = try f.store.send(id, undoWindow: .zero, origin: .app)
        #expect(try receipt.upsertOperationID == nil && f.op(receipt.sendOperationID).dependsOn == nil)
    }

    @Test func anOutOfRangeUndoWindowNeverTrapsAndIsCutToADay() throws {
        #expect(MailStore.windowMillis(.seconds(Int64.max)) == Int64.max)
        #expect(MailStore.windowMillis(.seconds(Int64.min)) == Int64.min)
        #expect(MailStore.windowMillis(.milliseconds(1500)) == 1500)
        #expect(SendMutations.holdMillis(.seconds(Int64.max)) == 86_400_000)
        #expect(SendMutations.holdMillis(.seconds(Int64.min)) == 0)
        #expect(SendMutations.holdMillis(.seconds(10)) == 10_000)
        let f = try MutationFixture()
        let held = try f.syncedDraft()
        let before = Date()
        let receipt = try f.store.send(held, undoWindow: .seconds(Int64.max), origin: .app)
        #expect(receipt.sendAfter >= before.addingTimeInterval(86_399))
        #expect(try f.claim(before.addingTimeInterval(86_000)).isEmpty)
        let immediate = try f.syncedDraft()
        let now = try f.store.send(immediate, undoWindow: .seconds(Int64.min), origin: .app)
        #expect(now.sendAfter < receipt.sendAfter)
    }

    @Test func onlyTheAppsSendActionOrTheSchedulerSendsAndADraftSendsOnce() throws {
        let f = try MutationFixture()
        let id = try f.syncedDraft()
        for origin in [OperationOrigin.cli, .agent] {
            #expect(throws: StoreError.self) { try f.store.send(id, undoWindow: .zero, origin: origin) }
        }
        #expect(try f.ops([.pending]).isEmpty && f.draftRow(id)["state"] as String == "editing")
        _ = try f.store.send(id, undoWindow: .seconds(10), origin: .app)
        #expect(throws: StoreError.self) { try f.store.send(id, undoWindow: .zero, origin: .app) }
        #expect(throws: StoreError.self) { _ = try f.store.updateDraft(id, content: MutationFixture.content("x"), expectedVersion: nil) }
        #expect(throws: StoreError.self) { _ = try f.store.discardDraft(id) }
        #expect(throws: StoreError.self) { _ = try f.store.saveDraftRemotely(id) }
        #expect(try f.ops([.pending]).filter { $0.kind == .sendDraft }.count == 1)
    }

    @Test func cancelSendWinsOnlyWhileNoAttemptCanHaveReachedGmail() throws {
        let f = try MutationFixture()
        let id = try f.syncedDraft()
        let a = try f.store.send(id, undoWindow: .seconds(10), origin: .app)
        #expect(try f.store.cancelSend(a))
        #expect(try f.draftRow(id)["state"] as String == "editing" && f.op(a.sendOperationID).status == .cancelled)
        #expect(try !f.store.cancelSend(a))
        let b = try f.store.send(id, undoWindow: .zero, origin: .app)
        _ = try f.claim()
        try f.store.release(b.sendOperationID, retryAt: Date().addingTimeInterval(30))
        #expect(try f.store.cancelSend(b))
        let c = try f.store.send(id, undoWindow: .zero, origin: .app)
        _ = try f.claim()
        #expect(try !f.store.cancelSend(c))
        try f.store.fail(c.sendOperationID, code: "transport", message: "timed out", retryAt: Date().addingTimeInterval(5))
        #expect(try !f.store.cancelSend(c) && f.draftRow(id)["state"] as String == "sending")
    }

    @Test func cancelSendAgainstTheDrainersClaimExactlyOneWins() async throws {
        let f = try MutationFixture()
        var cancelled = 0, claimed = 0
        for _ in 0..<100 {
            let id = try f.syncedDraft()
            let receipt = try f.store.send(id, undoWindow: .zero, origin: .app)
            let store = f.store, account = f.account
            async let claim = Task.detached {
                try store.claimReadyOperations(account: account, now: Date().addingTimeInterval(1), limit: 10, ownerID: "drainer")
                    .contains { $0.id == receipt.sendOperationID }
            }.value
            async let cancel = Task.detached { try store.cancelSend(receipt) }.value
            let (gotClaim, gotCancel) = try await (claim, cancel)
            #expect(gotClaim != gotCancel)
            let status = try f.op(receipt.sendOperationID).status
            #expect(status == (gotCancel ? .cancelled : .inFlight))
            #expect(try f.draftRow(id)["state"] as String == (gotCancel ? "editing" : "sending"))
            if gotCancel { cancelled += 1 } else { claimed += 1 }
        }
        #expect(cancelled + claimed == 100)
    }

    @Test func sendNowSkipsTheRestOfTheWindow() throws {
        let f = try MutationFixture()
        let id = try f.syncedDraft()
        let receipt = try f.store.send(id, undoWindow: .seconds(30), origin: .app)
        #expect(try f.claim().isEmpty)
        #expect(try f.store.sendNow(receipt))
        #expect(try f.claim().map(\.id) == [receipt.sendOperationID])
        #expect(try !f.store.sendNow(receipt))
    }

    @Test func aSentDraftIsFinalAndItsMessageJoinsTheThread() throws {
        let f = try MutationFixture()
        _ = try f.seed(1)
        let id = try f.syncedDraft(replyTo: "m1")
        let receipt = try f.store.send(id, undoWindow: .zero, origin: .app)
        _ = try f.claim()
        let sent = MessageUpsert.fixture("sent1", thread: "t1", minutes: 10, labels: ["SENT"], from: "me@example.com",
                                         to: ["bob@example.com"], history: 20)
        try f.store.complete(receipt.sendOperationID, outcome: .sent(sent))
        let row = try f.draftRow(id)
        #expect(try row["state"] as String == "sent" && row["tid"] as Int64? == f.ref("t1").rowID.rawValue)
        #expect(try f.view(.sent) == ["t1"] && f.store.thread(f.ref("t1"))?.messageCount == 2)
        #expect(try f.op(receipt.sendOperationID).status == .succeeded)
        #expect(throws: StoreError.self) { try f.store.send(id, undoWindow: .zero, origin: .app) }
        #expect(try f.store.discardDraft(id) == nil)
        #expect(throws: StoreError.self) { try f.store.complete(receipt.sendOperationID, outcome: .sent(sent)) }
    }

    @Test func aResyncStartingAsTheSentCopyIsStoredDoesNotSweepIt() throws {
        let f = try MutationFixture()
        _ = try f.seed(1)
        let id = try f.syncedDraft(replyTo: "m1")
        let receipt = try f.store.send(id, undoWindow: .zero, origin: .app)
        _ = try f.claim()
        let sent = MessageUpsert.fixture("sent-resync", thread: "t1", minutes: 10, labels: ["SENT"], from: "me@example.com",
                                         to: ["bob@example.com"], history: 20)
        let (store, account) = (f.store, f.account)
        UpsertRace.before("sent-resync") { _ = try? store.beginFullResync(account: account) }
        defer { UpsertRace.clear("sent-resync") }
        try f.store.complete(receipt.sendOperationID, outcome: .sent(sent))
        let generation = try f.store.syncStatus(account: account).generation
        #expect(generation == 2)
        _ = try f.store.sweepGeneration(account: account, olderThan: generation, newerThan: nil)
        #expect(try f.store.message(account: account, gmailMessageID: GmailMessageID("sent-resync")) != nil)
    }

    @Test func aPermanentFailureReopensTheDraftAndAFailedUploadFailsItsSendAtOnce() throws {
        let f = try MutationFixture()
        let id = try f.syncedDraft()
        let receipt = try f.store.send(id, undoWindow: .zero, origin: .app)
        _ = try f.claim()
        try f.store.fail(receipt.sendOperationID, code: "bad_request", message: "Invalid To header", retryAt: nil)
        let row = try f.draftRow(id)
        #expect(row["state"] as String == "failed" && row["last_error"] as String? == "Invalid To header")
        _ = try f.store.updateDraft(id, content: MutationFixture.content("Fixed"), expectedVersion: nil)
        let again = try f.store.send(id, undoWindow: .zero, origin: .app)
        let upload = try #require(again.upsertOperationID)
        _ = try f.claim()
        try f.store.fail(upload, code: "payload_too_large", message: "413", retryAt: nil)
        #expect(try f.op(again.sendOperationID).status == .failed && f.op(again.sendOperationID).lastErrorCode == "dependency_failed")
        #expect(try f.draftRow(id)["state"] as String == "failed")
    }

    @Test func overdueUndoSendsAreOnlyNeverClaimedOnesOlderThanAnHour() throws {
        let f = try MutationFixture()
        let drafts = try (0..<3).map { _ in try f.syncedDraft() }
        let a = try f.store.send(drafts[0], undoWindow: .seconds(10), origin: .app)
        let b = try f.store.send(drafts[1], undoWindow: .zero, origin: .app)
        _ = try f.claim()
        try f.store.release(b.sendOperationID, retryAt: Date().addingTimeInterval(60))
        let c = try f.store.send(drafts[2], undoWindow: .zero, origin: .app)
        _ = try f.claim()
        try f.store.fail(c.sendOperationID, code: "transport", message: "lost", retryAt: Date())
        #expect(try f.store.dueItems(account: f.account, now: Date().addingTimeInterval(1800)).overdueUndoSends.isEmpty)
        let overdue = try f.store.dueItems(account: f.account, now: Date().addingTimeInterval(7200)).overdueUndoSends
        #expect(overdue.map(\.id) == [a.sendOperationID])
        try f.store.write { db in
            try db.execute(sql: "UPDATE pending_operations SET not_before = not_before - 7200000 WHERE op_id = ?",
                           arguments: [a.sendOperationID.rawValue])
        }
        #expect(try f.store.cancelSend(a))
        #expect(try f.draftRow(drafts[0])["state"] as String == "editing")
        #expect(try f.draftRow(drafts[0])["last_error"] as String? == "send was interrupted")
    }

    @Test func theUsersSendOfAnAgentDraftIsItsReview() throws {
        let f = try MutationFixture()
        let id = try f.syncedDraft(origin: .agent, review: .pending)
        _ = try f.store.send(id, undoWindow: .seconds(5), origin: .app)
        #expect(try f.draftRow(id)["review_state"] as String == "approved")
    }
}
