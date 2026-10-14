import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct QueueLifecycleTests {
    let now = Date()

    @Test func claimTakesReadyOpsOnceInOrder() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(3)
        let a = try f.store.apply(.archive([refs[0]]), origin: .app)
        let b = try f.store.apply(.archive([refs[1]]), origin: .cli)
        let c = try f.store.apply(.archive([refs[2]]), origin: .app)
        let first = try f.store.claimReadyOperations(account: f.account, now: now, limit: 2, ownerID: "owner-1")
        #expect(first.map(\.id) == a.operationIDs + b.operationIDs)
        #expect(first.allSatisfy { $0.status == .inFlight })
        let second = try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "owner-1")
        #expect(second.map(\.id) == c.operationIDs)
        #expect(try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "owner-1").isEmpty)
        let claimedBy = try f.store.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT claimed_by FROM pending_operations")
        }
        #expect(claimedBy == ["owner-1"])
        #expect(try f.inbox().isEmpty)
    }

    @Test func completeFoldsTheDeltaSoEffectiveLabelsNeverRevert() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let receipt = try f.store.apply(.archive(refs), origin: .app)
        let id = receipt.operationIDs[0]
        var effective: [Set<String>] = [try f.labels("m1").effective]
        _ = try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "o")
        effective.append(try f.labels("m1").effective)
        try f.store.complete(id, outcome: .labelsApplied)
        effective.append(try f.labels("m1").effective)
        #expect(effective.allSatisfy { $0 == ["UNREAD"] })
        #expect(try f.labels("m1").server == ["UNREAD"])
        #expect(try f.op(id).status == .succeeded)
        #expect(try f.links(id) == 1)
        #expect(try f.inbox().isEmpty)
        #expect(try f.store.thread(refs[0])?.hasPendingChanges == false)
        #expect(throws: StoreError.self) { try f.store.complete(id, outcome: .labelsApplied) }
        _ = try f.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("m1"), historyID: HistoryID(2),
                                                     added: [], removed: [GmailLabelID("INBOX")])], account: f.account)
        #expect(try f.links(id) == 0 && f.inbox().isEmpty)
    }

    @Test func retryableFailureKeepsTheOverlayAndWaitsForItsRetryTime() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let id = try f.store.apply(.archive(refs), origin: .app).operationIDs[0]
        _ = try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "o")
        let retryAt = now.addingTimeInterval(5)
        try f.store.fail(id, code: "server", message: "503", retryAt: retryAt)
        let op = try f.op(id)
        #expect(op.status == .pending && op.attempts == 1 && op.lastErrorCode == "server")
        #expect(abs(op.nextRetryAt.timeIntervalSince(retryAt)) < 0.002)
        #expect(try f.inbox().isEmpty)
        #expect(try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "o").isEmpty)
        let wake = try #require(try f.store.nextWakeTime(account: f.account))
        #expect(abs(wake.timeIntervalSince(retryAt)) < 0.002)
        #expect(try f.store.claimReadyOperations(account: f.account, now: retryAt, limit: 10, ownerID: "o").map(\.id) == [id])
    }

    @Test func permanentFailureRevertsTheOverlay() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(2)
        let id = try f.store.apply(.archive([refs[0]]), origin: .app).operationIDs[0]
        #expect(try f.inbox() == ["t2"])
        _ = try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "o")
        try f.store.fail(id, code: "bad_request", message: "Invalid label", retryAt: nil)
        let op = try f.op(id)
        #expect(op.status == .failed && op.attempts == 1 && op.lastErrorMessage == "Invalid label")
        #expect(Set(try f.inbox()) == ["t1", "t2"])
        #expect(try f.links(id) == 0)
        #expect(try f.store.operations(account: f.account, statuses: [.failed], limit: 10).map(\.id) == [id])
        #expect(try f.store.nextWakeTime(account: f.account) == nil)
    }

    @Test func releaseKeepsAttemptsAndTheFirstClaim() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let id = try f.store.apply(.archive(refs), origin: .app).operationIDs[0]
        _ = try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "o")
        let firstClaim = try f.store.read { db in try Int64.fetchOne(db, sql: "SELECT claimed_at FROM pending_operations") }
        try f.store.release(id, retryAt: now.addingTimeInterval(30))
        let op = try f.op(id)
        #expect(op.status == .pending && op.attempts == 0)
        #expect(try f.inbox().isEmpty)
        _ = try f.store.claimReadyOperations(account: f.account, now: now.addingTimeInterval(31), limit: 10, ownerID: "o")
        let claimedAt = try f.store.read { db in try Int64.fetchOne(db, sql: "SELECT claimed_at FROM pending_operations") }
        #expect(claimedAt == firstClaim)
    }

    @Test func staleInFlightOpsAreRequeuedWithAnAttemptCounted() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let id = try f.store.apply(.archive(refs), origin: .app).operationIDs[0]
        _ = try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "dead-owner")
        #expect(try f.store.requeueStaleInFlight(account: f.account, claimedBefore: now.addingTimeInterval(1)) == 1)
        let op = try f.op(id)
        #expect(op.status == .pending && op.attempts == 1)
    }

    @Test func staleInFlightOpsOfALiveProcessAreLeftAloneUntilItEnds() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(3)
        let ours = try f.store.apply(.archive([refs[0]]), origin: .app).operationIDs[0]
        _ = try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: f.store.writerID)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let exit = ProcessExit()
        exit.attach(to: child)
        try child.run()
        #expect(exit.wait(child, timeout: 30, "/usr/bin/true"))
        try f.store.write { db in
            try db.execute(sql: "INSERT INTO change_feed (writer_id, pid, kind, seq, updated_at) VALUES (?, ?, 'test', 0, ?)",
                           arguments: ["suspended-app", Int(ProcessInfo.processInfo.processIdentifier), epochMillis(now)])
            try db.execute(sql: "INSERT INTO change_feed (writer_id, pid, kind, seq, updated_at) VALUES (?, ?, 'test', 0, ?)",
                           arguments: ["ended-app", Int(child.processIdentifier), epochMillis(now)])
        }
        let suspended = try f.store.apply(.archive([refs[1]]), origin: .app).operationIDs[0]
        _ = try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "suspended-app")
        let ended = try f.store.apply(.archive([refs[2]]), origin: .app).operationIDs[0]
        _ = try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "ended-app")
        #expect(try f.store.requeueStaleInFlight(account: f.account, claimedBefore: now.addingTimeInterval(1)) == 1)
        #expect(try f.op(ours).status == .inFlight && f.op(ours).attempts == 0)
        #expect(try f.op(suspended).status == .inFlight && f.op(suspended).attempts == 0)
        #expect(try f.op(ended).status == .pending && f.op(ended).attempts == 1)
    }

    @Test func aYoungerOpOnTheSameMessageWaitsForAnOlderRetryingOne() throws {
        // The archive's retry must run before the later move-to-inbox, or the older request wins on Gmail and the user's last action is lost
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        let archive = try f.store.apply(.archive(refs), origin: .app).operationIDs[0]
        _ = try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "o")
        let retryAt = now.addingTimeInterval(60)
        try f.store.fail(archive, code: "server", message: "503", retryAt: retryAt)
        let inbox = try f.store.apply(.moveToInbox(refs), origin: .app).operationIDs[0]
        #expect(try f.inbox() == ["t1"])
        #expect(try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "o").isEmpty)
        let wake = try #require(try f.store.nextWakeTime(account: f.account))
        #expect(abs(wake.timeIntervalSince(retryAt)) < 0.002)
        #expect(try f.store.claimReadyOperations(account: f.account, now: retryAt, limit: 10, ownerID: "o").map(\.id) == [archive])
        #expect(try f.store.claimReadyOperations(account: f.account, now: retryAt, limit: 10, ownerID: "o").isEmpty)
        try f.store.complete(archive, outcome: .labelsApplied)
        #expect(try f.store.claimReadyOperations(account: f.account, now: retryAt, limit: 10, ownerID: "o").map(\.id) == [inbox])
        try f.store.complete(inbox, outcome: .labelsApplied)
        #expect(try f.labels("m1").server.contains("INBOX") && f.inbox() == ["t1"])
    }

    @Test func aYoungerOpWaitsForAnOlderOneInFlightAndOtherTargetsAreNotHeldUp() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(2)
        let archive = try f.store.apply(.archive([refs[0]]), origin: .app).operationIDs[0]
        _ = try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "other-owner")
        let star = try f.store.apply(.star([refs[0]]), origin: .app).operationIDs[0]
        let other = try f.store.apply(.archive([refs[1]]), origin: .app).operationIDs[0]
        #expect(try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "o").map(\.id) == [other])
        #expect(try f.store.nextWakeTime(account: f.account) == nil)
        try f.store.fail(archive, code: "bad_request", message: "x", retryAt: nil)
        #expect(try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "o").map(\.id) == [star])
    }

    @Test func garbageCollectionKeepsRecentAndFailedRows() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(2)
        let done = try f.store.apply(.archive([refs[0]]), origin: .app).operationIDs[0]
        let bad = try f.store.apply(.archive([refs[1]]), origin: .app).operationIDs[0]
        _ = try f.store.claimReadyOperations(account: f.account, now: now, limit: 10, ownerID: "o")
        try f.store.complete(done, outcome: .labelsApplied)
        try f.store.fail(bad, code: "bad_request", message: "x", retryAt: nil)
        try f.store.garbageCollectOperations(now: Date())
        #expect(try f.store.operation(done) != nil)
        try f.store.garbageCollectOperations(now: Date().addingTimeInterval(2 * 3600))
        #expect(try f.store.operation(done) == nil)
        #expect(try f.store.operation(bad) != nil)
        try f.store.garbageCollectOperations(now: Date().addingTimeInterval(8 * 86_400))
        #expect(try f.store.operation(bad) == nil)
    }

    @Test func payloadJSONHasTheSpecShape() throws {
        let f = try MarkDoneFixture()
        let refs = try f.seed(1)
        _ = try f.store.apply(.archive(refs), origin: .app)
        let json = try f.store.read { db in try String.fetchOne(db, sql: "SELECT payload_json FROM pending_operations") }
        #expect(json == #"{"add":[],"ids":["m1"],"remove":["INBOX"]}"#)
        for payload: OperationPayload in [
            .trash(ids: [GmailMessageID("a")]), .untrash(ids: []), .createLabel(name: "X"),
            .upsertDraft(draftID: DraftID("d"), version: 3), .deleteDraft(draftID: DraftID("d"), gmailDraftID: nil),
            .sendDraft(draftID: DraftID("d")),
            .modifyLabels(ids: [], add: [GmailLabelID("L")], remove: [], addNames: ["OpenHuman/Snoozed"]),
        ] {
            let kind = OperationPayloadCodec.kind(of: payload)
            #expect(try OperationPayloadCodec.decode(kind: kind, json: OperationPayloadCodec.encode(payload)) == payload)
        }
    }
}
