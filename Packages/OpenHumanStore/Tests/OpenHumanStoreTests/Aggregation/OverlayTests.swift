import Foundation
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct OverlayTests {
    @Test func staleSyncReAddingInboxDoesNotBringAnArchivedThreadBack() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let id = try f.store.apply(.archive(refs), origin: .app).operationIDs[0]
        _ = try f.store.upsertMessages([.fixture("m1", thread: "t1", minutes: 1, labels: ["INBOX", "UNREAD", "STARRED"],
                                                 history: 5)], account: f.account, generation: 1)
        _ = try f.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("m1"), historyID: HistoryID(6),
                                                     added: [GmailLabelID("INBOX")], removed: [])], account: f.account)
        #expect(try f.inbox().isEmpty)
        let m1 = try f.labels("m1")
        #expect(m1.effective == ["UNREAD", "STARRED"] && m1.server == ["INBOX", "UNREAD", "STARRED"])
        #expect(try f.store.thread(refs[0])?.isStarred == true)

        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "o")
        try f.store.complete(id, outcome: .labelsApplied)
        #expect(try f.labels("m1").server == ["UNREAD", "STARRED"])
        _ = try f.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("m1"), historyID: HistoryID(7),
                                                     added: [], removed: [GmailLabelID("INBOX")])], account: f.account)
        #expect(try f.inbox().isEmpty)
    }

    @Test func permanentFailureAfterAStaleSyncShowsTheServerState() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let id = try f.store.apply(.archive(refs), origin: .app).operationIDs[0]
        _ = try f.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("m1"), historyID: HistoryID(6),
                                                     added: [], removed: [GmailLabelID("UNREAD")])], account: f.account)
        try f.store.fail(id, code: "bad_request", message: "x", retryAt: nil)
        #expect(try f.inbox() == ["t1"])
        #expect(try f.labels("m1").effective == ["INBOX"])
        #expect(try f.store.label(account: f.account, key: "INBOX")?.unreadThreads == 0)
    }

    @Test func liveOpsApplyInOpOrder() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let archive = try f.store.apply(.archive(refs), origin: .app)
        _ = try f.store.claimReadyOperations(account: f.account, now: Date(), limit: 10, ownerID: "o")
        _ = try f.store.undo(archive, origin: .app)
        _ = try f.store.apply(.archive(refs), origin: .app)
        #expect(try f.inbox().isEmpty)
        #expect(try f.store.operations(account: f.account, statuses: [.pending, .inFlight], limit: 10).count == 3)
    }

    @Test func trashAndUntrashFollowTheTable() throws {
        var set: Set<String> = ["INBOX", "SPAM", "UNREAD"]
        LabelOverlay.apply(.trash(ids: []), to: &set) { _ in nil }
        #expect(set == ["TRASH", "UNREAD"])
        LabelOverlay.apply(.untrash(ids: []), to: &set) { _ in nil }
        #expect(set == ["UNREAD"])
        LabelOverlay.apply(.createLabel(name: "x"), to: &set) { _ in nil }
        #expect(set == ["UNREAD"])
    }

    @Test func addNamesResolveOnceTheLabelRowExistsAndTheFoldUsesThem() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX"])])
        let op = try f.op(["m1"], addNames: ["Clients/Acme"])
        #expect(try f.store.message(account: f.account, gmailMessageID: GmailMessageID("m1"))?.labelIDs == [GmailLabelID("INBOX")])
        try f.labels([("Label_42", "Clients/Acme")])
        #expect(try f.store.thread(f.ref("t1"))?.userLabelIDs.count == 1)
        let fold = try f.store.read { db in
            try LabelOverlay.fold(.modifyLabels(ids: [], add: [], remove: [], addNames: ["Clients/Acme"]), into: "INBOX",
                                  account: f.account.rawValue, in: db)
        }
        #expect(fold == "INBOX,Label_42")
        _ = op
    }

    @Test func recomputeWritesOnlyChangedRows() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX"])])
        let before = try f.store.read { try Int64.fetchOne($0, sql: "SELECT updated_at FROM messages") }
        let changes = try f.store.write { db -> Int in
            let total = db.totalChangesCount
            try LabelOverlay.recompute(mids: Set(try Int64.fetchAll(db, sql: "SELECT mid FROM messages")), in: db)
            return db.totalChangesCount - total
        }
        #expect(changes == 0)
        #expect(try f.store.read { try Int64.fetchOne($0, sql: "SELECT updated_at FROM messages") } == before)
    }
}
