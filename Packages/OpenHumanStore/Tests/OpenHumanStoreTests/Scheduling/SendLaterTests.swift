import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct SendLaterTests {
    private func header(_ f: MutationFixture, _ id: DraftID) throws -> String? {
        DraftRowCodec.header(OHGmailLabels.sendAtHeader, in: DraftRowCodec.decodeHeaders(try f.draftRow(id)["extra_headers_json"]))
    }

    private func scheduled(_ f: MutationFixture, at: Date = nine, now: Date = nine.addingTimeInterval(-3600),
                           origin: DraftOrigin = .user, review: DraftReviewState = .none) throws -> DraftID {
        _ = try f.seed(1)
        let id = try f.syncedDraft(origin: origin, review: review, replyTo: "m1")
        try schedule(f, id, at: at, now: now)
        try f.drain()
        return id
    }

    private func schedule(_ f: MutationFixture, _ id: DraftID, at: Date, now: Date = nine.addingTimeInterval(-3600)) throws {
        try f.store.write { db in try SendMutations.schedule(id, at: at, now: epochMillis(now), in: db) }
    }

    @Test func aTimeThatIsNotInTheFutureIsNeverScheduled() throws {
        let f = try MutationFixture()
        _ = try f.seed(1)
        let id = try f.syncedDraft(replyTo: "m1")
        let before = try f.draftRow(id)
        for at in [Date().addingTimeInterval(-60), Date(), Date().addingTimeInterval(-86_400 * 2)] {
            #expect(throws: StoreError.self) { try f.store.scheduleSend(id, at: at) }
        }
        let now = nine.addingTimeInterval(-30)
        for at in [now, nine.addingTimeInterval(-10), nine.addingTimeInterval(-3600)] {
            #expect(throws: StoreError.self) { try schedule(f, id, at: at, now: now) }
        }
        let after = try f.draftRow(id)
        #expect(after["state"] as String == "editing" && after["send_at"] as Int64? == nil)
        #expect(after["local_version"] as Int == before["local_version"] as Int)
        #expect(try header(f, id) == nil)
        #expect(try f.ops([.pending]).isEmpty)
        try schedule(f, id, at: nine, now: now)
        #expect(try f.draftRow(id)["send_at"] as Int64? == epochMillis(nine))
        #expect(throws: StoreError.self) { try schedule(f, id, at: nine, now: nine) }
    }

    @Test func scheduleSendIsLocalIntentUntilTheUploadLands() throws {
        let f = try MutationFixture()
        _ = try f.seed(1)
        let id = try f.syncedDraft(replyTo: "m1")
        let version = try f.draftRow(id)["local_version"] as Int
        try schedule(f, id, at: nine.addingTimeInterval(42))
        let row = try f.draftRow(id)
        #expect(row["state"] as String == "scheduled" && row["send_at"] as Int64? == epochMillis(nine))
        #expect(try header(f, id) == "20261012T0900Z")
        #expect(row["local_version"] as Int == version + 1 && row["synced_version"] as Int == version)
        let upload = try #require(try f.ops([.pending]).first)
        #expect(upload.payload == .upsertDraft(draftID: id, version: version + 1))
        #expect(try f.threadRow("t1")["scheduled_send_at"] as Int64? == epochMillis(nine) && f.view(.scheduled) == ["t1"])
        #expect(try f.store.dueItems(account: f.account, now: ten).scheduledSendsDue.isEmpty)
        try f.drain()
        #expect(try f.draftRow(id)["state"] as String == "scheduled")
        #expect(try f.store.dueItems(account: f.account, now: nine.addingTimeInterval(-1)).scheduledSendsDue.isEmpty)
        let due = try f.store.dueItems(account: f.account, now: nine).scheduledSendsDue
        #expect(try due.map(\.id) == [id] && due.first?.sendAt == nine && due.first?.thread == f.ref("t1"))
        #expect(try f.store.nextDueTime(account: f.account, kinds: [.sendLater]) == nine)
    }

    @Test func rescheduleAndCancel() throws {
        let f = try MutationFixture()
        let id = try scheduled(f)
        try schedule(f, id, at: ten)
        #expect(try header(f, id) == "20261012T1000Z" && f.draftRow(id)["send_at"] as Int64? == epochMillis(ten))
        let version = try f.draftRow(id)["local_version"] as Int
        try schedule(f, id, at: ten.addingTimeInterval(30))
        #expect(try f.draftRow(id)["local_version"] as Int == version)
        try f.store.cancelScheduledSend(id)
        let row = try f.draftRow(id)
        #expect(try row["state"] as String == "editing" && row["send_at"] as Int64? == nil && header(f, id) == nil)
        #expect(try f.threadRow("t1")["scheduled_send_at"] as Int64? == nil && f.view(.scheduled).isEmpty)
        try f.drain()
        #expect(try f.draftRow(id)["state"] as String == "editing")
        try f.store.cancelScheduledSend(id)
        #expect(try f.draftRow(id)["local_version"] as Int == version + 1)
    }

    @Test func anUnreviewedAgentDraftCanNeverBeScheduled() throws {
        let f = try MutationFixture()
        _ = try f.seed(1)
        let id = try f.syncedDraft(origin: .agent, review: .pending, replyTo: "m1")
        #expect(throws: StoreError.self) { try schedule(f, id, at: nine) }
        try f.store.setReviewState(id, .approved)
        try schedule(f, id, at: nine)
        try f.drain()
        _ = try f.store.updateAgentDraft(id, content: MutationFixture.content("Rewritten"), agentNote: nil)
        let row = try f.draftRow(id)
        #expect(try row["review_state"] as String == "pending" && row["state"] as String == "editing" && header(f, id) == nil)
    }

    @Test func theSchedulersSendNeedsASyncedScheduledDraftAndHappensOnce() throws {
        let f = try MutationFixture()
        let id = try scheduled(f)
        let receipt = try f.store.send(id, undoWindow: .zero, origin: .scheduler)
        #expect(receipt.upsertOperationID == nil)
        let op = try f.op(receipt.sendOperationID)
        #expect(op.kind == .sendDraft && op.origin == .scheduler && op.coalesceKey == nil && op.dependsOn == nil)
        #expect(try f.draftRow(id)["state"] as String == "sending")
        #expect(try f.store.dueItems(account: f.account, now: ten).scheduledSendsDue.isEmpty)
        #expect(throws: StoreError.self) { try f.store.send(id, undoWindow: .zero, origin: .scheduler) }
        #expect(throws: StoreError.self) { try f.store.send(id, undoWindow: .zero, origin: .app) }
        let other = try f.newDraft(replyTo: "m1")
        try schedule(f, other, at: nine)
        #expect(throws: StoreError.self) { try f.store.send(other, undoWindow: .zero, origin: .scheduler) }
    }

    @Test func aScheduledAgentDraftThatLostItsReviewIsRefusedByTheStoreToo() throws {
        let f = try MutationFixture()
        let id = try scheduled(f, origin: .agent, review: .approved)
        try f.store.write { db in try db.execute(sql: "UPDATE drafts SET review_state = 'pending'") }
        #expect(throws: StoreError.self) { try f.store.send(id, undoWindow: .zero, origin: .scheduler) }
    }

    @Test func aMissedSendNeedsAttentionAndStaysThatWay() throws {
        let f = try MutationFixture()
        let id = try scheduled(f)
        try f.store.markScheduledSendNeedsAttention(id, reason: "missed")
        let row = try f.draftRow(id)
        #expect(row["state"] as String == "failed" && row["last_error"] as String? == "scheduled time passed while Mail was closed")
        #expect(row["send_at"] as Int64? == epochMillis(nine))
        #expect(try f.store.dueItems(account: f.account, now: ten).scheduledSendsDue.isEmpty)
        #expect(try f.threadRow("t1")["scheduled_send_at"] as Int64? == nil)
        _ = try f.store.apply(.star([try f.ref("t1")]), origin: .app)
        #expect(try f.draftRow(id)["state"] as String == "failed")
        try f.store.markScheduledSendNeedsAttention(id, reason: ScheduleDerivation.unreadableScheduleError)
        #expect(try f.draftRow(id)["last_error"] as String? == "scheduled time unreadable (needs attention)")
        _ = try f.store.updateDraft(id, content: MutationFixture.content("Edited"), expectedVersion: nil)
        #expect(try f.draftRow(id)["state"] as String == "editing" && header(f, id) == nil)
        #expect(throws: StoreError.notFound("draft nope")) {
            try f.store.markScheduledSendNeedsAttention(DraftID("nope"), reason: "missed")
        }
    }

    @Test func aStaleScheduleGoesBackToTheRunnerAndAConsumedDraftIsDiscarded() throws {
        let f = try MutationFixture()
        let id = try scheduled(f)
        let first = try f.store.send(id, undoWindow: .zero, origin: .scheduler)
        try f.store.fail(first.sendOperationID, code: "stale_schedule", message: "older than 2 minutes", retryAt: nil)
        #expect(try f.op(first.sendOperationID).status == .cancelled && f.draftRow(id)["state"] as String == "scheduled")
        #expect(try f.store.dueItems(account: f.account, now: ten).scheduledSendsDue.map(\.id) == [id])
        let second = try f.store.send(id, undoWindow: .zero, origin: .scheduler)
        _ = try f.claim()
        try f.store.fail(second.sendOperationID, code: "target_gone", message: "draft 404 at step 3a", retryAt: nil)
        #expect(try f.op(second.sendOperationID).status == .cancelled && f.draftRow(id)["state"] as String == "discarded")
        #expect(try f.ops([.failed]).isEmpty)
        #expect(try f.store.dueItems(account: f.account, now: ten).scheduledSendsDue.isEmpty)
    }

    @Test func theLaunchReconcileNeverListsTheSchedulersOwnSend() throws {
        let f = try MutationFixture()
        let id = try scheduled(f, at: Date().addingTimeInterval(-7200), now: Date().addingTimeInterval(-3 * 3600))
        let other = try f.syncedDraft(replyTo: "m1")
        let receipt = try f.store.send(id, undoWindow: .zero, origin: .scheduler)
        let later = Date().addingTimeInterval(2 * 3600)
        #expect(try f.store.dueItems(account: f.account, now: later).overdueUndoSends.isEmpty)
        #expect(try f.op(receipt.sendOperationID).status == .pending && f.draftRow(id)["state"] as String == "sending")
        let mine = try f.store.send(other, undoWindow: .seconds(10), origin: .app)
        #expect(try f.store.dueItems(account: f.account, now: later).overdueUndoSends.map(\.id) == [mine.sendOperationID])
    }

    @Test func cancellingTheSchedulersQueuedSendDropsTheSchedule() throws {
        let f = try MutationFixture()
        let id = try scheduled(f)
        let receipt = try f.store.send(id, undoWindow: .zero, origin: .scheduler)
        let op = try #require(try f.claim().first)
        try f.store.release(op.id, retryAt: Date().addingTimeInterval(30))
        #expect(try f.store.cancelSend(receipt))
        #expect(try f.draftRow(id)["state"] as String == "editing" && header(f, id) == nil)
        #expect(try f.ops([.pending]).map(\.kind) == [.upsertDraft])
    }
}
