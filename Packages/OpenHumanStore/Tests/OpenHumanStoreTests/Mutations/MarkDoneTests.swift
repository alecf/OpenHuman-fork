import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

struct MarkDoneFixture {
    let store: MailStore
    let account: AccountID

    init() throws {
        (store, account) = try OpenHumanStoreTesting.storeWithAccount()
    }

    @discardableResult
    func seed(_ count: Int = 3) throws -> [ThreadRef] {
        let messages = (1...count).map { MessageUpsert.fixture("m\($0)", thread: "t\($0)", minutes: $0, labels: ["INBOX", "UNREAD"]) }
        _ = try store.upsertMessages(messages, account: account, generation: 1)
        return try (1...count).map { try ref("t\($0)") }
    }

    func ref(_ thread: String) throws -> ThreadRef {
        try #require(try store.thread(account: account, gmailThreadID: GmailThreadID(thread)))
    }

    func inbox() throws -> [String] {
        try store.threadPage(view: .system(account, .inbox), after: nil, limit: 100).items.map(\.ref.gmailThreadID.rawValue)
    }

    func allMail() throws -> [String] {
        try store.threadPage(view: .system(account, .allMail), after: nil, limit: 100).items.map(\.ref.gmailThreadID.rawValue)
    }

    func labels(_ message: String) throws -> (effective: Set<String>, server: Set<String>) {
        try store.read { db in
            let row = try #require(try Row.fetchOne(db, sql: """
                SELECT label_ids, server_label_ids FROM messages WHERE gmail_message_id = ?
                """, arguments: [message]))
            return (Labels.split(row["label_ids"]), Labels.split(row["server_label_ids"]))
        }
    }

    func links(_ op: OperationID) throws -> Int {
        try store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM pending_op_messages WHERE op_id = ?", arguments: [op.rawValue]) ?? 0
        }
    }

    func op(_ id: OperationID) throws -> OperationItem { try #require(try store.operation(id)) }
}

@Suite struct MarkDoneTests {
    @Test func markDoneLeavesTheInboxAtOnceAndQueuesOneModifyLabelsOp() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(3)
        let receipt = try f.store.apply(.archive([refs[0], refs[2]]), origin: .app)

        #expect(receipt.operationIDs.count == 1)
        #expect(receipt.undo == .moveToInbox([refs[0], refs[2]]))
        #expect(try f.inbox() == ["t2"])
        #expect(Set(try f.allMail()) == ["t1", "t2", "t3"])
        let op = try f.op(receipt.operationIDs[0])
        #expect(op.status == .pending && op.kind == .modifyLabels && op.attempts == 0 && op.origin == .app)
        #expect(op.payload == .modifyLabels(ids: [GmailMessageID("m1"), GmailMessageID("m3")], add: [],
                                            remove: [GmailLabelID("INBOX")], addNames: []))
        #expect(op.coalesceKey == "labels:\(f.account.rawValue):|INBOX")
        let m1 = try f.labels("m1")
        #expect(m1.effective == ["UNREAD"] && m1.server == ["INBOX", "UNREAD"])
        #expect(try f.links(op.id) == 2)
        #expect(try f.store.thread(refs[0])?.hasPendingChanges == true)
        #expect(try f.store.thread(refs[1])?.hasPendingChanges == false)
        #expect(try f.store.label(account: f.account, key: "INBOX")?.totalThreads == 1)
    }

    @Test func snapshotHoldsTheVisibleMessagesKnownNow() throws {
        let f = try MarkDoneFixture()
        _ = try f.store.upsertMessages([
            .fixture("a1", thread: "t1", minutes: 1, labels: ["INBOX"]),
            .fixture("a2", thread: "t1", minutes: 2, labels: ["TRASH"]),
            .fixture("a3", thread: "t1", minutes: 3, labels: ["DRAFT"]),
            .fixture("a4", thread: "t1", minutes: 4, labels: ["INBOX", "UNREAD"]),
        ], account: f.account, generation: 1)
        let receipt = try f.store.apply(.archive([try f.ref("t1")]), origin: .app)
        let op = try f.op(try #require(receipt.operationIDs.first))
        guard case let .modifyLabels(ids, _, _, _) = op.payload else { Issue.record("wrong payload"); return }
        #expect(ids == [GmailMessageID("a1"), GmailMessageID("a4")])
        _ = try f.store.upsertMessages([.fixture("a5", thread: "t1", minutes: 5, labels: ["INBOX"])],
                                       account: f.account, generation: 1)
        #expect(try f.labels("a5").effective == ["INBOX"])
        #expect(try f.inbox() == ["t1"])
    }

    @Test func oneOpPerAccountAndNothingForUnknownThreads() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let other = try f.store.addAccount(email: "other@example.com", displayName: nil, scopes: [])
        try f.store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: other, removeMissing: false)
        _ = try f.store.upsertMessages([.fixture("o1", thread: "o-t1", labels: ["INBOX"])], account: other, generation: 1)
        let otherRef = try #require(try f.store.thread(account: other, gmailThreadID: GmailThreadID("o-t1")))
        let receipt = try f.store.apply(.archive([otherRef, refs[0]]), origin: .app)
        #expect(receipt.operationIDs.count == 2)
        #expect(try receipt.operationIDs.map { try f.op($0).accountID } == [f.account, other])

        let ghost = ThreadRef(accountID: f.account, rowID: ThreadRowID(rawValue: 9_999), gmailThreadID: GmailThreadID("x"))
        let empty = try f.store.apply(.archive([ghost]), origin: .app)
        #expect(empty.operationIDs.isEmpty && empty.undo == nil)
        #expect(try f.store.undo(empty, origin: .app) == nil)
    }

    @Test func undoWhilePendingCancelsWithoutAnInverseAndRedoReapplies() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(2)
        let receipt = try f.store.apply(.archive([refs[0]]), origin: .app)
        #expect(try f.inbox() == ["t2"])

        let redo = try #require(try f.store.undo(receipt, origin: .app))
        #expect(redo.operationIDs.isEmpty)
        #expect(redo.undo == .archive([refs[0]]))
        #expect(try f.op(receipt.operationIDs[0]).status == .cancelled)
        #expect(try f.links(receipt.operationIDs[0]) == 0)
        #expect(Set(try f.inbox()) == ["t1", "t2"])
        #expect(try f.labels("m1").effective == ["INBOX", "UNREAD"])
        #expect(try f.store.thread(refs[0])?.hasPendingChanges == false)
        #expect(try f.store.operations(account: f.account, statuses: [.pending], limit: 10).isEmpty)

        let again = try #require(try f.store.undo(redo, origin: .app))
        #expect(again.operationIDs.count == 1 && again.operationIDs != receipt.operationIDs)
        #expect(again.undo == .moveToInbox([refs[0]]))
        #expect(try f.inbox() == ["t2"])
        #expect(try f.store.undo(receipt, origin: .app) == nil)
    }

    @Test func undoAfterTheOpWasClaimedEnqueuesTheInverse() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let receipt = try f.store.apply(.archive(refs), origin: .app)
        let claimed = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "test")
        #expect(claimed.map(\.id) == receipt.operationIDs)

        let undone = try #require(try f.store.undo(receipt, origin: .app))
        #expect(undone.undo == .archive(refs))
        let inverse = try f.op(try #require(undone.operationIDs.first))
        #expect(inverse.payload == .modifyLabels(ids: [GmailMessageID("m1")], add: [GmailLabelID("INBOX")], remove: [], addNames: []))
        #expect(try f.op(receipt.operationIDs[0]).status == .inFlight)
        #expect(try f.inbox() == ["t1"])

        try f.store.complete(receipt.operationIDs[0], outcome: .labelsApplied)
        #expect(try f.inbox() == ["t1"])
        #expect(try f.labels("m1").server == ["UNREAD"])
        let next = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "test")
        #expect(next.map(\.id) == undone.operationIDs)
        try f.store.complete(undone.operationIDs[0], outcome: .labelsApplied)
        let m1 = try f.labels("m1")
        #expect(m1.effective == ["INBOX", "UNREAD"] && m1.server == ["INBOX", "UNREAD"])
        #expect(try f.store.thread(refs[0])?.hasPendingChanges == false)
    }

    @Test func undoAfterSuccessEnqueuesTheInverseAndAPermanentFailureHasNothingToUndo() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(2)
        let done = try f.store.apply(.archive([refs[0]]), origin: .app)
        let failed = try f.store.apply(.archive([refs[1]]), origin: .app)
        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "test")
        try f.store.complete(done.operationIDs[0], outcome: .labelsApplied)
        try f.store.fail(failed.operationIDs[0], code: "bad_request", message: "rejected", retryAt: nil)

        let inverse = try #require(try f.store.undo(done, origin: .app))
        #expect(inverse.operationIDs.count == 1 && inverse.undo == .archive([refs[0]]))
        #expect(try f.store.undo(failed, origin: .app) == nil)
        #expect(Set(try f.inbox()) == ["t1", "t2"])
    }

    @Test func aPendingRetryIsNotCancelledBecauseItMayHaveReachedGmail() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let receipt = try f.store.apply(.archive(refs), origin: .app)
        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "test")
        try f.store.fail(receipt.operationIDs[0], code: "server", message: "503", retryAt: Date().addingTimeInterval(5))
        let undone = try #require(try f.store.undo(receipt, origin: .app))
        #expect(undone.operationIDs.count == 1)
        #expect(try f.op(receipt.operationIDs[0]).status == .pending)
        #expect(try f.inbox() == ["t1"])
    }

    @Test func dismissFailedOperationRemovesOnlyFailedRows() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(2)
        let a = try f.store.apply(.archive([refs[0]]), origin: .app)
        let b = try f.store.apply(.archive([refs[1]]), origin: .app)
        try f.store.fail(a.operationIDs[0], code: "bad_request", message: "x", retryAt: nil)
        try f.store.dismissFailedOperation(a.operationIDs[0])
        try f.store.dismissFailedOperation(b.operationIDs[0])
        #expect(try f.store.operation(a.operationIDs[0]) == nil)
        #expect(try f.store.operation(b.operationIDs[0])?.status == .pending)
    }

    @Test func removedAccountsRefuseMutations() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        try f.store.setAccountStatus(f.account, .removing)
        #expect(throws: StoreError.accountNotActive(f.account)) { try f.store.apply(.archive(refs), origin: .app) }
        try f.store.setAccountStatus(f.account, .needsReauth)
        #expect(try f.store.apply(.archive(refs), origin: .app).operationIDs.count == 1)
    }

    @Test func markDoneOnAThreadAlreadyOutOfTheInboxQueuesNothing() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let done = try f.store.apply(.archive(refs), origin: .app)
        let again = try f.store.apply(.archive(refs), origin: .app)
        #expect(again.operationIDs.isEmpty && again.undo == nil)
        #expect(try f.store.operations(account: f.account, statuses: [], limit: 10).map(\.id) == done.operationIDs)
    }
}
