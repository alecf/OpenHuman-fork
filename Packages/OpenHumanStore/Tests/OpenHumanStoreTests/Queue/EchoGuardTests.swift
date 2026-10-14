import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct EchoGuardTests {
    private func delta(_ message: String, _ history: UInt64, added: [String] = [], removed: [String] = []) -> LabelDelta {
        LabelDelta(gmailMessageID: GmailMessageID(message), historyID: HistoryID(history),
                   added: added.map { GmailLabelID($0) }, removed: removed.map { GmailLabelID($0) })
    }

    private func staleFetch(_ f: MarkDoneFixture, history: UInt64 = 1, labels: [String] = ["INBOX", "UNREAD"]) throws {
        _ = try f.store.upsertMessages([.fixture("m1", thread: "t1", minutes: 1, labels: labels, history: history)],
                                       account: f.account, generation: 1)
    }

    private func archiveAndApply(_ f: MarkDoneFixture, _ refs: [ThreadRef]) throws -> ActionReceipt {
        let receipt = try f.store.apply(.archive(refs), origin: .app)
        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "o")
        for id in receipt.operationIDs { try f.store.complete(id, outcome: .labelsApplied) }
        return receipt
    }

    @Test func aFetchAnsweredBeforeGmailAppliedTheArchiveLandsAfterItAndTheThreadStaysDone() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let id = try archiveAndApply(f, refs).operationIDs[0]
        #expect(try f.inbox().isEmpty)

        try staleFetch(f)
        #expect(try f.inbox().isEmpty, "a read from before Gmail applied the archive brought the thread back")
        #expect(try f.labels("m1").effective == ["UNREAD"])
        #expect(try f.links(id) == 1, "the change waits for Gmail's record of it")
        #expect(try f.store.thread(refs[0])?.hasPendingChanges == false, "it reached Gmail: no pending mark")

        _ = try f.store.applyLabelDeltas([delta("m1", 2, removed: ["INBOX"])], account: f.account)
        #expect(try f.links(id) == 0)
        #expect(try f.inbox().isEmpty)
        try staleFetch(f)
        #expect(try f.inbox().isEmpty)
    }

    @Test func archiveUndoArchiveSurvivesAHistoryPageListedBeforeTheLastArchive() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let first = try archiveAndApply(f, refs)
        let back = try #require(try f.store.undo(first, origin: .app))
        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "o")
        try f.store.complete(back.operationIDs[0], outcome: .labelsApplied)
        let again = try archiveAndApply(f, refs)
        #expect(try f.inbox().isEmpty)

        _ = try f.store.applyLabelDeltas([delta("m1", 2, removed: ["INBOX"]), delta("m1", 3, added: ["INBOX"])],
                                         account: f.account)
        #expect(try f.inbox().isEmpty, "the move back in the stale page undid the second archive")
        #expect(try f.links(first.operationIDs[0]) == 0 && f.links(back.operationIDs[0]) == 0)
        #expect(try f.links(again.operationIDs[0]) == 1)

        _ = try f.store.applyLabelDeltas([delta("m1", 4, removed: ["INBOX"])], account: f.account)
        #expect(try f.inbox().isEmpty && f.links(again.operationIDs[0]) == 0)
    }

    @Test func aChangeMadeElsewhereAfterOursShowsOnceGmailsRecordOfOursArrived() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let id = try archiveAndApply(f, refs).operationIDs[0]
        _ = try f.store.applyLabelDeltas([delta("m1", 2, removed: ["INBOX"]), delta("m1", 3, added: ["INBOX"])],
                                         account: f.account)
        #expect(try f.links(id) == 0)
        #expect(try f.inbox() == ["t1"])
    }

    @Test func aFetchThatShowsTheChangeEndsTheGuardAndOlderReadsAreSkippedByHistoryID() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let id = try archiveAndApply(f, refs).operationIDs[0]
        try staleFetch(f, history: 2, labels: ["UNREAD"])
        #expect(try f.links(id) == 0)
        try staleFetch(f, history: 1)
        #expect(try f.inbox().isEmpty)
    }

    @Test func aRecordCarryingSeveralLabelsEchoesOneChangeOnly() throws {
        let f = try MarkDoneFixture()
        try f.store.upsertLabels([LabelUpsert(gmailLabelID: GmailLabelID("Label_1"), name: "Acme", type: "user")],
                                 account: f.account, removeMissing: false)
        let refs = try f.seed(1)
        let move = try f.store.apply(.modifyLabels(refs, add: [GmailLabelID("Label_1")], remove: [GmailLabelID("INBOX")]),
                                     origin: .app)
        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "o")
        try f.store.complete(move.operationIDs[0], outcome: .labelsApplied)
        let back = try #require(try f.store.undo(move, origin: .app))
        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "o")
        try f.store.complete(back.operationIDs[0], outcome: .labelsApplied)
        let done = try archiveAndApply(f, refs)
        _ = try f.store.applyLabelDeltas([delta("m1", 2, added: ["Label_1"]), delta("m1", 2, removed: ["INBOX"])],
                                         account: f.account)
        #expect(try f.links(move.operationIDs[0]) == 0)
        #expect(try f.links(back.operationIDs[0]) == 1 && f.links(done.operationIDs[0]) == 1)
        #expect(try f.inbox().isEmpty)
    }

    @Test func aSyncBeforeWhileQueuedAndWhileInFlightNeverShowsTheThreadAgain() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        try staleFetch(f)
        let receipt = try f.store.apply(.archive(refs), origin: .app)
        let id = receipt.operationIDs[0]
        try staleFetch(f)
        _ = try f.store.applyLabelDeltas([delta("m1", 1, added: ["INBOX"])], account: f.account)
        #expect(try f.inbox().isEmpty)
        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "o")
        try staleFetch(f)
        #expect(try f.inbox().isEmpty)
        try f.store.complete(id, outcome: .labelsApplied)
        try staleFetch(f)
        #expect(try f.inbox().isEmpty)
    }

    @Test func offlineThenOnlineKeepsItDoneThroughEveryStaleRead() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let id = try f.store.apply(.archive(refs), origin: .app).operationIDs[0]
        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "o")
        try f.store.release(id, retryAt: Date())
        try staleFetch(f)
        #expect(try f.inbox().isEmpty)
        _ = try f.store.claimReadyOperations(account: f.account, now: Date().addingTimeInterval(1), limit: 10, ownerID: "o")
        try f.store.complete(id, outcome: .labelsApplied)
        try staleFetch(f)
        #expect(try f.inbox().isEmpty)
        _ = try f.store.applyLabelDeltas([delta("m1", 2, removed: ["INBOX"])], account: f.account)
        #expect(try f.links(id) == 0 && f.inbox().isEmpty)
    }

    @Test func undoAfterGmailAppliedTheArchiveBringsItBackAndKeepsItBack() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let archive = try archiveAndApply(f, refs)
        let back = try #require(try f.store.undo(archive, origin: .app))
        #expect(back.operationIDs.count == 1, "it reached Gmail: undo is the inverse change")
        #expect(try f.inbox() == ["t1"])
        try staleFetch(f, history: 2, labels: ["UNREAD"])
        #expect(try f.inbox() == ["t1"])
        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "o")
        try f.store.complete(back.operationIDs[0], outcome: .labelsApplied)
        try staleFetch(f, history: 2, labels: ["UNREAD"])
        #expect(try f.inbox() == ["t1"])
        _ = try f.store.applyLabelDeltas([delta("m1", 2, removed: ["INBOX"]), delta("m1", 3, added: ["INBOX"])],
                                         account: f.account)
        #expect(try f.links(archive.operationIDs[0]) == 0 && f.links(back.operationIDs[0]) == 0)
        #expect(try f.inbox() == ["t1"])
    }

    @Test func twoAccountsKeepTheirOwnGuards() throws {
        let f = try MarkDoneFixture()
        let other = try f.store.addAccount(email: "other@example.com", displayName: "Other", scopes: ["gmail.readonly"])
        try f.store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: other, removeMissing: false)
        let mine = try f.seed(1)
        _ = try f.store.upsertMessages([.fixture("o1", thread: "u1", minutes: 2, labels: ["INBOX"])], account: other,
                                       generation: 1)
        let theirs = try #require(try f.store.thread(account: other, gmailThreadID: GmailThreadID("u1")))
        let receipt = try f.store.apply(.archive(mine + [theirs]), origin: .app)
        #expect(receipt.operationIDs.count == 2, "one op per account")
        for account in [f.account, other] {
            _ = try f.store.claimReadyOperations(account: account, now: Date(), limit: 10, ownerID: "o")
        }
        for id in receipt.operationIDs { try f.store.complete(id, outcome: .labelsApplied) }

        try staleFetch(f)
        _ = try f.store.upsertMessages([.fixture("o1", thread: "u1", minutes: 2, labels: ["INBOX"])], account: other,
                                       generation: 1)
        func otherInbox() throws -> [String] {
            try f.store.threadPage(view: .system(other, .inbox), after: nil, limit: 10).items.map(\.ref.gmailThreadID.rawValue)
        }
        #expect(try f.inbox().isEmpty && otherInbox().isEmpty)
        _ = try f.store.applyLabelDeltas([delta("m1", 2, removed: ["INBOX"])], account: f.account)
        let mineOp = try #require(try receipt.operationIDs.first { try f.op($0).accountID == f.account })
        let theirOp = try #require(try receipt.operationIDs.first { try f.op($0).accountID == other })
        #expect(try f.links(mineOp) == 0 && f.links(theirOp) == 1)
        #expect(try otherInbox().isEmpty)
    }

    @Test func aTrashGmailAnsweredWithTheMessageNeedsNoGuard() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let id = try f.store.apply(.trash(refs), origin: .app).operationIDs[0]
        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "o")
        try f.store.complete(id, outcome: .messagesReturned([.fixture("m1", thread: "t1", minutes: 1,
                                                                        labels: ["TRASH", "UNREAD"], history: 5)]))
        #expect(try f.links(id) == 0, "Gmail's copy carries the history id: older reads are skipped by it")
        try staleFetch(f, history: 4)
        #expect(try f.inbox().isEmpty && f.labels("m1").effective == ["TRASH", "UNREAD"])
    }

    @Test func aPermanentFailureStillRevertsAtOnce() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let id = try f.store.apply(.archive(refs), origin: .app).operationIDs[0]
        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "o")
        try f.store.fail(id, code: "bad_request", message: "x", retryAt: nil)
        #expect(try f.links(id) == 0 && f.inbox() == ["t1"])
    }

    @Test func theGuardEndsAfterItsWindowWhenNoEchoCame() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let id = try archiveAndApply(f, refs).operationIDs[0]
        try staleFetch(f)
        #expect(try f.inbox().isEmpty)
        try f.store.garbageCollectOperations(now: Date())
        #expect(try f.links(id) == 1)
        try f.store.garbageCollectOperations(now: Date().addingTimeInterval(MailStore.echoGuardWindow.timeInterval + 1))
        #expect(try f.links(id) == 0)
        #expect(try f.inbox() == ["t1"])
    }

    @Test func aFinishedSyncPassEndsGuardsOlderThanTheWindow() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(2)
        let old = try archiveAndApply(f, [refs[0]]).operationIDs[0]
        let recent = try archiveAndApply(f, [refs[1]]).operationIDs[0]
        let window = Int64(MailStore.echoGuardWindow.timeInterval * 1000)
        try f.store.write { db in
            try db.execute(sql: "UPDATE pending_operations SET updated_at = updated_at - ? WHERE op_id = ?",
                           arguments: [window + 1000, old.rawValue])
        }
        try f.store.updateSyncState(account: f.account) { $0.historyID = HistoryID(9) }
        #expect(try f.links(old) == 0 && f.links(recent) == 1)
    }
}

@Suite struct HoldPolicyTests {
    @Test func reversibleChangesAreReadyAtOnceAndOnlyASendIsHeld() throws {
        let f = try MutationFixture()
        try f.labels([("Label_1", "Acme")])
        let refs = try f.seed(6)
        var receipts: [ActionReceipt] = []
        receipts.append(try f.store.apply(.archive([refs[0]]), origin: .app))
        receipts.append(try f.store.apply(.markRead([refs[1]]), origin: .app))
        receipts.append(try f.store.apply(.star([refs[2]]), origin: .app))
        receipts.append(try f.store.apply(.trash([refs[3]]), origin: .app))
        receipts.append(try f.store.apply(.markSpam([refs[4]]), origin: .app))
        receipts.append(try f.store.apply(.modifyLabels([refs[5]], add: [GmailLabelID("Label_1")], remove: []), origin: .app))
        let ids = receipts.flatMap(\.operationIDs)
        #expect(ids.count == 6)
        for id in ids { #expect(try f.op(id).notBefore == Date(timeIntervalSince1970: 0)) }
        let ready = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 50, ownerID: "o")
        #expect(Set(ready.map(\.id)) == Set(ids), "nothing reversible waits for a window")

        let draft = try f.newDraft()
        let send = try f.store.send(draft, undoWindow: .seconds(10), origin: .app)
        #expect(try f.op(send.sendOperationID).notBefore > Date().addingTimeInterval(8))
        let claimed = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 50, ownerID: "o")
        #expect(!claimed.contains { $0.id == send.sendOperationID }, "a send waits out its undo window")
    }
}
