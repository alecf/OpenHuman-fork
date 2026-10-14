import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct SendCommitTests {
    @Test func aSendBlockedOnItsUploadIsCommittedWhenItsWindowEnds() throws {
        let f = try MutationFixture()
        let id = try f.newDraft()
        let receipt = try f.store.send(id, undoWindow: .seconds(10), origin: .app)
        let upload = try #require(receipt.upsertOperationID)
        #expect(try f.claim().map(\.id) == [upload])
        try f.store.release(upload, retryAt: Date().addingTimeInterval(30))
        #expect(try f.raw("SELECT claimed_at FROM pending_operations WHERE op_id = ?", [receipt.sendOperationID.rawValue])
                    .first?["claimed_at"] as Int64? == nil)
        #expect(try f.claim(Date().addingTimeInterval(11)).isEmpty)
        let send = try f.op(receipt.sendOperationID)
        #expect(send.status == .pending && send.attempts == 0)
        #expect(try f.store.dueItems(account: f.account, now: Date().addingTimeInterval(7200)).overdueUndoSends.isEmpty)
        #expect(try f.store.cancelSend(receipt))
        #expect(try f.draftRow(id)["state"] as String == "editing" && f.draftRow(id)["last_error"] as String? == nil)
    }

    @Test func draftReadsCarryTheUploadFields() throws {
        let f = try MutationFixture()
        _ = try f.seed(1)
        let headers = ["In-Reply-To": "<m1@example.com>", "References": "<m1@example.com>", "X-OpenHuman-Origin": "cli"]
        let id = try f.newDraft(origin: .cli, review: .pending, replyTo: "m1", headers: headers)
        var item = try #require(try f.store.draft(id))
        #expect(item.localVersion == 1 && item.gmailMessageID == nil && item.extraHeaders == headers)
        #expect(item.gmailThreadID?.rawValue == "t1" && item.thread?.gmailThreadID.rawValue == "t1")
        _ = try f.store.saveDraftRemotely(id)
        try f.drain()
        _ = try f.store.updateAgentDraft(id, content: MutationFixture.content("Again"), agentNote: nil)
        item = try #require(try f.store.draft(id))
        #expect(item.localVersion == 2 && item.isDirty && item.gmailMessageID?.rawValue.hasPrefix("dm-") == true)
        #expect(try f.store.drafts(account: f.account, states: [], limit: 10).first == item)
    }
}
