import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import SQLite3
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

    @Test func anAgentDraftGoesToGmailDraftsMarkedAndIsNeverSent() async throws {
        let h = try await WriteHarness()
        let events = EventLog()
        let drainer = h.drainer(api: try h.client, events: events)
        let id = try h.newDraft(origin: .cli, review: .pending, headers: ["X-OpenHuman-Origin": "cli"])
        let upload = try h.store.saveDraftRemotely(id)
        #expect(try h.store.operation(upload)?.origin == .cli)
        await drainer.drainOnce()
        #expect(try h.store.operation(upload)?.status == .succeeded)
        let draft = try h.draft(id)
        #expect(draft.reviewState == .pending && !draft.isDirty)
        let kept = try #require(draft.gmailDraftID).rawValue
        let message = try #require(draft.gmailMessageID).rawValue
        #expect(lines(h.uploads()[0].raw, startingWith: "x-openhuman-origin:") == ["X-OpenHuman-Origin: cli"])
        #expect(await h.labelNames(ofMessage: message).contains(OHGmailLabels.agent))
        #expect(try h.store.reviewQueue(account: h.account).map(\.id) == [id])

        let other = try h.newDraft(origin: .agent, review: .pending, headers: ["X-OpenHuman-Origin": "agent"])
        let otherUpload = try h.store.saveDraftRemotely(other)
        #expect(try h.store.operation(otherUpload)?.origin == .agent)
        await drainer.drainOnce()
        #expect(try h.store.operation(otherUpload)?.status == .succeeded)
        let removed = try #require(try h.draft(other).gmailDraftID).rawValue
        #expect(try await h.gmailDraftIDs().contains(removed))

        let delete = try #require(try h.store.discardDraft(other))
        #expect(try h.store.operation(delete)?.origin == .agent)
        await drainer.drainOnce()
        #expect(try h.store.operation(delete)?.status == .succeeded)
        let remaining = try await h.gmailDraftIDs()
        #expect(remaining.contains(kept) && !remaining.contains(removed))
        #expect(events.failedOperations.isEmpty && events.sendFailures.isEmpty)
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        #expect(await h.gmail.callCount(.sendMessage) == 0)
        #expect(try await h.sentOnGmail().isEmpty)
    }

    @Test func fromTheCliOrAnAgentOnlyChangesToAnAgentsOwnDraftsPass() async throws {
        let h = try await WriteHarness(threads: 1)
        let drainer = h.drainer(api: h.gmail)
        var drafts: [(name: String, id: DraftID, agents: Bool)] = [
            ("user", try h.newDraft(), false),
            ("user approved", try h.newDraft(review: .approved), false),
            ("missing", DraftID("no-such-draft"), false),
        ]
        for origin in [DraftOrigin.cli, .agent] {
            for review in [DraftReviewState.pending, .approved, .rejected] {
                drafts.append(("\(origin.rawValue) \(review.rawValue)", try h.newDraft(origin: origin, review: review), true))
            }
        }
        let message = GmailMessageID("m-synthetic")
        let mailChanges: [OperationPayload] = [
            .modifyLabels(ids: [message], add: [GmailLabelID("STARRED")], remove: [], addNames: []),
            .modifyLabels(ids: [message], add: [], remove: [GmailLabelID("INBOX")], addNames: ["Synthetic"]),
            .trash(ids: [message]), .untrash(ids: [message]), .createLabel(name: "Synthetic"),
        ]
        func draftChanges(_ id: DraftID) -> (upsert: OperationPayload, delete: OperationPayload, send: OperationPayload) {
            (upsert: OperationPayload.upsertDraft(draftID: id, version: 1),
             delete: OperationPayload.deleteDraft(draftID: id, gmailDraftID: GmailDraftID("r-synthetic")),
             send: OperationPayload.sendDraft(draftID: id))
        }
        func refusal(_ payload: OperationPayload, _ origin: OperationOrigin) async -> String? {
            guard let decision = await drainer.externalRefusal(Self.item(payload, origin, account: h.account, at: h.clock.now))
            else { return nil }
            guard case let .fail(code, _) = decision.disposition else { return "not a failure" }
            return code
        }
        let refused = "not_applied_outside_app"

        for origin in [OperationOrigin.app, .scheduler] {
            for payload in mailChanges { #expect(await refusal(payload, origin) == nil, "\(origin) \(payload)") }
            for draft in drafts {
                let change = draftChanges(draft.id)
                for payload in [change.upsert, change.delete, change.send] {
                    #expect(await refusal(payload, origin) == nil, "\(origin) \(draft.name) \(payload)")
                }
            }
        }
        for origin in [OperationOrigin.cli, .agent] {
            for payload in mailChanges { #expect(await refusal(payload, origin) == refused, "\(origin) \(payload)") }
            for draft in drafts {
                let change = draftChanges(draft.id)
                let expected: String? = draft.agents ? nil : refused
                #expect(await refusal(change.upsert, origin) == expected, "\(origin) upsert \(draft.name)")
                #expect(await refusal(change.delete, origin) == expected, "\(origin) delete \(draft.name)")
                #expect(await refusal(change.send, origin) == refused, "\(origin) send \(draft.name)")
            }
        }
    }

    @Test(arguments: ["cli", "agent"])
    func aSendQueuedFromOutsideTheAppFailsWithoutReachingGmailEvenWhenApproved(origin: String) async throws {
        let h = try await WriteHarness(clock: sendClock(), onDisk: true)
        let events = EventLog()
        let drainer = h.drainer(api: try h.client, events: events)
        let id = try h.newDraft(origin: .cli, review: .pending, headers: ["X-OpenHuman-Origin": "cli"])
        try h.store.setReviewState(id, .approved)
        await drainer.drainOnce()
        let draft = try h.draft(id)
        #expect(draft.reviewState == .approved && draft.gmailDraftID != nil && !draft.isDirty)

        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        #expect(receipt.upsertOperationID == nil)
        try Self.setQueuedOrigin(origin, of: receipt.sendOperationID, in: h.store)
        #expect(try h.store.operation(receipt.sendOperationID)?.origin.rawValue == origin)
        h.advancePast(receipt)
        let before = h.wire.requests.count

        let report = await drainer.drainOnce()
        #expect(report.claimed == 1 && report.failed == 1 && report.gmailCalls == 0)
        let op = try #require(try h.store.operation(receipt.sendOperationID))
        #expect(op.status == .failed && op.lastErrorCode == "not_applied_outside_app")
        #expect(h.wire.requests.count == before)
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        #expect(await h.gmail.callCount(.sendMessage) == 0)
        #expect(try await h.sentOnGmail().isEmpty)
        #expect(try h.draft(id).state != .sent)
        #expect(events.sendFailures.map { $0.0 } == [id])
    }

    static func item(_ payload: OperationPayload, _ origin: OperationOrigin, account: AccountID, at date: Date) -> OperationItem {
        let kind: OperationKind
        switch payload {
        case .modifyLabels: kind = .modifyLabels
        case .trash: kind = .trash
        case .untrash: kind = .untrash
        case .upsertDraft: kind = .upsertDraft
        case .deleteDraft: kind = .deleteDraft
        case .sendDraft: kind = .sendDraft
        case .createLabel: kind = .createLabel
        }
        return OperationItem(id: OperationID(rawValue: 1), accountID: account, kind: kind, payload: payload, status: .inFlight,
                             attempts: 0, notBefore: date, nextRetryAt: date, origin: origin, createdAt: date, updatedAt: date)
    }

    // Why: no store API queues a send from the CLI or an agent, so the row is rewritten the way another process could
    static func setQueuedOrigin(_ origin: String, of op: OperationID, in store: MailStore) throws {
        struct RawWriteFailed: Error {}
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.location.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw RawWriteFailed()
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        let sql = "UPDATE pending_operations SET origin = '\(origin)' WHERE op_id = \(op.rawValue) AND status = 'pending'"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sqlite3_changes(db) == 1 else { throw RawWriteFailed() }
    }
}
