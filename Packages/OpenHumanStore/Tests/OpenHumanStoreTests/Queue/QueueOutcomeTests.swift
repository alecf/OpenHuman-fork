import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct QueueOutcomeTests {
    @Test func returnedMessagesCarryGmailsLabelsUnlessTheRowIsNewer() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("a1", thread: "t1", labels: ["INBOX", "UNREAD"], history: 5),
                      .fixture("a2", thread: "t1", minutes: 1, labels: ["INBOX"], history: 5)])
        let receipt = try f.store.apply(.trash([try f.ref("t1")]), origin: .app)
        let op = try #require(try f.claim().first)
        #expect(op.id == receipt.operationIDs[0])
        try f.store.complete(op.id, outcome: .messagesReturned([
            .fixture("a1", thread: "t1", labels: ["TRASH", "UNREAD"], history: 7),
            .fixture("a2", thread: "t1", minutes: 1, labels: ["INBOX"], history: 4),
        ]))
        #expect(try f.server("a1") == ["TRASH", "UNREAD"] && f.server("a2") == ["TRASH"])
        #expect(try f.effective("a1") == ["TRASH", "UNREAD"] && f.view(.trash) == ["t1"])
        #expect(try f.raw("SELECT history_id FROM messages WHERE gmail_message_id = 'a1'").first?["history_id"] as Int64? == 7)
    }

    @Test func aFailedLabelCreationFailsItsDependentsAtOnceAndRevertsTheOverlay() throws {
        let f = try MutationFixture()
        let refs = try f.seed(2)
        let receipt = try f.store.apply(.snooze([refs[0]], until: nine), origin: .app)
        #expect(try f.inbox() == ["t2"])
        let marker = try #require(try f.claim().first)
        try f.store.fail(marker.id, code: "bad_request", message: "Invalid label name", retryAt: nil)
        let statuses = try receipt.operationIDs.map { try f.op($0) }
        #expect(statuses.map(\.status) == [.failed, .failed, .failed])
        #expect(statuses.dropFirst().allSatisfy { $0.lastErrorCode == "dependency_failed" && $0.attempts == 0 })
        #expect(try Set(f.inbox()) == ["t1", "t2"] && f.snoozeRow("t1") == nil)
        #expect(try f.ops([.failed]).count == 3)
    }

    @Test func aCancelledDependencyFailsItsDependentsAtTheNextClaim() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        let receipt = try f.store.apply(.createLabel(f.account, name: "Clients", applyTo: refs), origin: .app)
        try f.store.write { db in
            try db.execute(sql: "UPDATE pending_operations SET status = 'cancelled' WHERE op_id = ?",
                           arguments: [receipt.operationIDs[0].rawValue])
        }
        #expect(try f.claim().isEmpty)
        #expect(try f.op(receipt.operationIDs[1]).status == .failed && f.op(receipt.operationIDs[1]).lastErrorCode == "dependency_failed")
    }

    @Test func coalesceKeysMergeEqualLabelChangesOnly() throws {
        let f = try MutationFixture()
        let refs = try f.seed(4)
        let a = try f.store.apply(.archive([refs[0]]), origin: .app)
        let b = try f.store.apply(.archive([refs[1]]), origin: .cli)
        let nineOp = try f.store.apply(.snooze([refs[2]], until: nine), origin: .app)
        let tenOp = try f.store.apply(.snooze([refs[3]], until: ten), origin: .app)
        #expect(try f.op(a.operationIDs[0]).coalesceKey == f.op(b.operationIDs[0]).coalesceKey)
        let nineModify = try #require(nineOp.operationIDs.last), tenModify = try #require(tenOp.operationIDs.last)
        let k9 = try #require(try f.op(nineModify).coalesceKey)
        let k10 = try #require(try f.op(tenModify).coalesceKey)
        #expect(k9 != k10 && k9.hasSuffix(snooze9) && k10.hasSuffix(snooze10))
        #expect(try f.ops([.pending]).filter { $0.kind == .createLabel }.count == 3)
        _ = try f.store.apply(.moveToInbox([refs[0]]), origin: .app)
        try f.drain()
        _ = try f.store.apply(.setReminder(refs[0], dueAt: nine, condition: .always), origin: .app)
        let id = try #require(try f.store.activeReminders(account: f.account, limit: 1).first?.reminder.id)
        _ = try f.store.apply(.archive([refs[0]]), origin: .app)
        let fired = try #require(try f.store.fireReminder(id, now: nine, satisfied: false))
        #expect(try f.op(fired.operationIDs[0]).coalesceKey == nil)
    }

    @Test func outcomesMustFitTheirOperation() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        let receipt = try f.store.apply(.archive(refs), origin: .app)
        _ = try f.claim()
        for wrong: OperationOutcome in [.draftDeleted, .labelCreated(LabelUpsert(gmailLabelID: GmailLabelID("L"), name: "L", type: "user")),
                                        .draftSaved(gmailDraftID: GmailDraftID("r"), gmailMessageID: GmailMessageID("m"), version: 1),
                                        .sent(.fixture("s1", thread: "t1", labels: ["SENT"]))] {
            #expect(throws: StoreError.self) { try f.store.complete(receipt.operationIDs[0], outcome: wrong) }
        }
        #expect(try f.op(receipt.operationIDs[0]).status == .inFlight)
        #expect(throws: StoreError.notFound("operation 999")) { try f.store.complete(OperationID(rawValue: 999), outcome: .labelsApplied) }
    }

    @Test func aLabelCreatedElsewhereFirstIsTheSameRow() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        _ = try f.store.apply(.snooze(refs, until: nine), origin: .app)
        try f.labels([("L_mark", OHGmailLabels.snoozed)])
        let create = try #require(try f.claim().first)
        try f.store.complete(create.id, outcome: .labelCreated(LabelUpsert(gmailLabelID: GmailLabelID("L_mark"),
                                                                           name: OHGmailLabels.snoozed, type: "user")))
        #expect(try f.raw("SELECT count(*) AS n FROM labels WHERE name = ?", [OHGmailLabels.snoozed]).first?["n"] as Int? == 1)
        try f.drain()
        #expect(try f.server("m1").contains("L_mark"))
    }

    @Test func garbageCollectionKeepsAnOpALiveOpStillDependsOn() throws {
        let f = try MutationFixture()
        let id = try f.syncedDraft()
        _ = try f.store.updateDraft(id, content: MutationFixture.content("Two"), expectedVersion: nil)
        let receipt = try f.store.send(id, undoWindow: .seconds(3600), origin: .app)
        let upload = try #require(receipt.upsertOperationID)
        _ = try f.claim()
        try f.store.complete(upload, outcome: .draftSaved(gmailDraftID: GmailDraftID("r"), gmailMessageID: GmailMessageID("dm2"),
                                                          version: 2))
        try f.store.garbageCollectOperations(now: Date().addingTimeInterval(2 * 3600))
        #expect(try f.store.operation(upload) != nil)
        #expect(try f.store.claimReadyOperations(account: f.account, now: Date().addingTimeInterval(3601), limit: 10,
                                                 ownerID: "o").map(\.id) == [receipt.sendOperationID])
    }

    @Test func requeuedSendAfterACrashCountsAnAttemptAndCanNoLongerBeCancelled() throws {
        let f = try MutationFixture()
        let id = try f.syncedDraft()
        let receipt = try f.store.send(id, undoWindow: .zero, origin: .app)
        _ = try f.claim()
        #expect(try f.store.requeueStaleInFlight(account: f.account, claimedBefore: Date().addingTimeInterval(60)) == 1)
        #expect(try f.op(receipt.sendOperationID).attempts == 1 && !f.store.cancelSend(receipt))
    }
}
