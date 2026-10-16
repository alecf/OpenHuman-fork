import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct ExternalOriginTests {
    @Test func aCliChangeNeverReachesGmail() async throws {
        let h = try await WriteHarness(threads: 2)
        let thread = h.threads[0]
        let events = EventLog()
        let drainer = h.drainer(api: try h.client, events: events)
        let receipt = try h.store.apply(.archive([try h.ref(thread)]), origin: .cli)
        #expect(!(try h.inbox()).contains(thread))
        let before = h.wire.requests.count

        let refused = await drainer.drainOnce()
        #expect(refused.claimed == 1 && refused.failed == 1 && refused.gmailCalls == 0)
        let op = try #require(try h.store.operation(receipt.operationIDs[0]))
        #expect(op.status == .failed && op.lastErrorCode == "not_applied_outside_app")
        #expect(h.wire.requests.count == before)
        #expect(await h.serverLabels(ofThread: thread).contains("INBOX"))
        #expect(try h.inbox().contains(thread))
        #expect(events.failedOperations.map(\.id) == [op.id])

        let agent = try h.store.apply(.star([try h.ref(thread)]), origin: .agent)
        let mine = try h.store.apply(.star([try h.ref(h.threads[1])]), origin: .app)
        let report = await drainer.drainOnce()
        #expect(report.claimed == 2 && report.failed == 1 && report.succeeded == 1)
        #expect(try h.store.operation(agent.operationIDs[0])?.lastErrorCode == "not_applied_outside_app")
        #expect(try h.store.operation(mine.operationIDs[0])?.status == .succeeded)
        #expect(!(await h.serverLabels(ofThread: thread)).contains("STARRED"))
        #expect(await h.serverLabels(ofThread: h.threads[1]).contains("STARRED"))
        #expect(h.wire.nonGETRequests.count == 1)
    }

    @Test func anAgentDraftUploadsOnlyOnceTheUserReviewedIt() async throws {
        let h = try await WriteHarness()
        let drainer = h.drainer(api: try h.client)
        let id = try h.newDraft(origin: .cli, review: .pending, headers: ["X-OpenHuman-Origin": "cli"])
        let pending = try h.store.saveDraftRemotely(id)
        await drainer.drainOnce()
        #expect(try h.store.operation(pending)?.lastErrorCode == "not_applied_outside_app")
        #expect(h.uploads().isEmpty)
        #expect(try h.draft(id).gmailDraftID == nil)

        try h.store.setReviewState(id, .approved)
        let reviewed = try #require(try h.store.operations(account: h.account, statuses: [.pending], limit: 10).first)
        #expect(reviewed.kind == .upsertDraft && reviewed.origin == .app)
        await drainer.drainOnce()
        #expect(try h.store.operation(reviewed.id)?.status == .succeeded)
        #expect(h.uploads().count == 1)
        #expect(try h.draft(id).gmailDraftID != nil)

        let second = try h.newDraft(origin: .cli, review: .pending, headers: ["X-OpenHuman-Origin": "cli"])
        let agentUpload = try h.store.saveDraftRemotely(second)
        try h.store.setReviewState(second, .approved)
        #expect(try h.store.operation(agentUpload)?.origin == .cli)
        await drainer.drainOnce()
        #expect(try h.store.operation(agentUpload)?.status == .succeeded)
        #expect(h.uploads().count == 2)
        #expect(await h.gmail.callCount(.sendDraft) == 0)
    }
}
