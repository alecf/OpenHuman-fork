import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct ExternalOriginTests {
    @Test func aCliChangeNeverReachesGmailWithoutTheGuard() async throws {
        let h = try await WriteHarness(threads: 2)
        let thread = h.threads[0]
        let receipt = try h.store.apply(.archive([try h.ref(thread)]), origin: .cli)
        let mine = try h.store.apply(.star([try h.ref(h.threads[1])]), origin: .app)
        #expect(!(try h.inbox()).contains(thread))
        let events = EventLog()

        let report = await h.drainer(api: try h.client, events: events).drainOnce()
        #expect(report.claimed == 2 && report.failed == 1 && report.succeeded == 1)
        let op = try #require(try h.store.operation(receipt.operationIDs[0]))
        #expect(op.status == .failed && op.lastErrorCode == "safe_mode_blocked")
        #expect(try h.store.operation(mine.operationIDs[0])?.status == .succeeded)
        #expect(await h.serverLabels(ofThread: thread).contains("INBOX"))
        #expect(try h.inbox().contains(thread))
        #expect(events.failedOperations.map(\.id) == [op.id])
        #expect(h.wire.requests.filter { $0.method != "GET" && !$0.url.path().hasPrefix("/batch/") }.count == 1)
    }

    @Test func behindTheGuardACliChangeRunsUntilItIsADayOld() async throws {
        let clock = InstantClock(now: Date())
        let h = try await WriteHarness(clock: clock, threads: 2)
        let fresh = try h.store.apply(.star([try h.ref(h.threads[0])]), origin: .cli)
        let drainer = h.drainer(api: try h.client, external: true)
        #expect(await drainer.drainOnce().succeeded == 1)
        #expect(try h.store.operation(fresh.operationIDs[0])?.status == .succeeded)
        #expect(await h.gmail.callCount(.batchModify) == 1)

        let old = try h.store.apply(.star([try h.ref(h.threads[1])]), origin: .cli)
        clock.advance(by: OperationDrainer.externalMaxAge + .seconds(60))
        let report = await drainer.drainOnce()
        #expect(report.failed == 1 && report.gmailCalls == 0)
        #expect(try h.store.operation(old.operationIDs[0])?.lastErrorCode == "expired")
        #expect(await h.gmail.callCount(.batchModify) == 1)
        #expect(!(await h.serverLabels(ofThread: h.threads[1])).contains("STARRED"))
    }

    @Test func anAgentDraftUploadsOnlyOnceTheUserReviewedIt() async throws {
        let h = try await WriteHarness()
        let drainer = h.drainer(api: try h.client)
        let id = try h.newDraft(origin: .cli, review: .pending, headers: ["X-OpenHuman-Origin": "cli"])
        let pending = try h.store.saveDraftRemotely(id)
        await drainer.drainOnce()
        #expect(try h.store.operation(pending)?.lastErrorCode == "safe_mode_blocked")
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

    @Test func readOnlyRefusesTheApprovalAndQueuesNothing() async throws {
        let h = try await EngineHarness(safeMode: .readOnly)
        let id = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                         content: DraftContent(to: [], cc: [], bcc: [], subject: "Agent draft",
                                                               bodyHTML: "<p>Synthetic</p>", attachments: []),
                                         origin: .cli, reviewState: .pending, agentNote: nil, extraHeaders: [:])
        await #expect(throws: EngineError.self) { try await h.engine(safeMode: .readOnly).setReviewState(id, .approved) }
        #expect(try h.store.draft(id)?.reviewState == .pending)
        #expect(try h.store.operations(account: h.account, statuses: [.pending], limit: 10).isEmpty)
    }

    @Test func theGuardIsWriteAllowlistInTheEngineAndTheFactory() async throws {
        let h = try await WriteHarness()
        let account = try #require(try h.store.accounts().first)
        func factory(_ mode: SafeMode) -> DefaultGmailClientFactory {
            DefaultGmailClientFactory(safeMode: mode, apiTransport: h.wire, config: GmailClientConfig(userAgent: "t"),
                                      clock: h.clock) { _ in (StaticTokenProvider(), [GmailScope.modify]) }
        }
        #expect(!EnginePolicy.drainsExternalOps(safeMode: .normal, factory: factory(.normal), account: account))
        #expect(!EnginePolicy.drainsExternalOps(safeMode: .readOnly, factory: factory(.readOnly), account: account))
        #expect(!EnginePolicy.drainsExternalOps(safeMode: .writeAllowlist, factory: factory(.normal), account: account))
        #expect(EnginePolicy.drainsExternalOps(safeMode: .writeAllowlist, factory: factory(.writeAllowlist), account: account))
    }
}
