import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanMIME
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct SendPipelineTests {
    @Test func undoInsideTheWindowNeverSends() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .seconds(10), origin: .app)
        await drainer.drainOnce()
        #expect(await h.gmail.callCount(.createDraft) == 1)
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        #expect(try h.store.cancelSend(receipt))
        h.advancePast(receipt)
        await drainer.drainOnce()
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        #expect(try h.draft(id).state == .editing)
        #expect(try await h.sentOnGmail().isEmpty)
        #expect(try await h.gmailDraftIDs().count == 1)
    }

    @Test func afterTheWindowItSendsExactlyOnceThroughTheClientStack() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let events = EventLog()
        let drainer = h.drainer(api: try h.client, events: events)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .seconds(10), origin: .app)
        await drainer.drainOnce()
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        h.advancePast(receipt)
        let report = await drainer.drainOnce()
        #expect(report.succeeded == 1 && report.failed == 0)
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        let sent = try await h.sentOnGmail()
        #expect(sent.count == 1)
        #expect(try h.draft(id).state == .sent)
        #expect(events.sent.map(\.0) == [id] && events.sent.first?.1?.rawValue == sent.first)
        let stored = try #require(try h.store.message(account: h.account, gmailMessageID: GmailMessageID(sent[0])))
        #expect(stored.subject == "Synthetic draft" && stored.labelIDs.contains(GmailLabelID("SENT")))
        #expect(stored.to.map(\.email) == ["bob@example.com"])
        #expect(try await h.gmailDraftIDs().isEmpty)
        #expect(await drainer.drainOnce().claimed == 0)
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        let writes = h.wire.nonGETRequests.map { "\($0.method) \($0.url.path())" }
        #expect(writes == ["POST /upload/gmail/v1/users/me/drafts", "POST /gmail/v1/users/me/drafts/send"])
        try await h.syncer.sync(reason: "poll")
        #expect(try h.draft(id).state == .sent)
        #expect(try await h.sentOnGmail().count == 1)
    }

    @Test func offlineAtTheWindowEndCommitsButTheSendStaysCancellable() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .seconds(10), origin: .app)
        await drainer.drainOnce()
        await h.gmail.failNext(.sendDraft, with: .transport(.notConnected))
        h.advancePast(receipt)
        let report = await drainer.drainOnce()
        #expect(report.released == 1 && report.retried == 0)
        let op = try #require(try h.store.operation(receipt.sendOperationID))
        #expect(op.status == .pending && op.attempts == 0)
        #expect(try h.store.dueItems(account: h.account, now: h.clock.now.addingTimeInterval(7200)).overdueUndoSends.isEmpty)
        #expect(try h.store.cancelSend(receipt))
        #expect(try h.draft(id).state == .editing)
        #expect(try await h.sentOnGmail().isEmpty)
    }

    @Test func sendComposedOfflineIsCommittedAtTheWindowEndEvenBeforeItsUpload() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .seconds(10), origin: .app)
        await h.gmail.failNext(.createDraft, with: .transport(.notConnected))
        await drainer.drainOnce()
        h.advancePast(receipt)
        await drainer.drainOnce()
        let send = try #require(try h.store.operation(receipt.sendOperationID))
        #expect(send.status == .pending && send.attempts == 0)
        #expect(try h.store.dueItems(account: h.account, now: h.clock.now.addingTimeInterval(7200)).overdueUndoSends.isEmpty)
        h.instant.advance(by: .seconds(7200))
        _ = try h.store.requeueStaleInFlight(account: h.account, claimedBefore: h.clock.now)
        await h.drainer(api: h.gmail).drainOnce()
        #expect(try await h.sentOnGmail().count == 1)
        #expect(try h.draft(id).state == .sent)
        #expect(await h.gmail.callCount(.sendDraft) == 1)
    }

    @Test func committedOfflineSendIsNotUndoneByARelaunchAndSendsOnceOnline() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .seconds(10), origin: .app)
        await h.drainer(api: h.gmail).drainOnce()
        await h.gmail.failNext(.sendDraft, with: .transport(.notConnected))
        h.advancePast(receipt)
        await h.drainer(api: h.gmail).drainOnce()
        h.instant.advance(by: .seconds(7200))
        #expect(try h.store.requeueStaleInFlight(account: h.account, claimedBefore: h.clock.now) == 0)
        #expect(try h.store.dueItems(account: h.account, now: h.clock.now).overdueUndoSends.isEmpty)
        let report = await h.drainer(api: h.gmail).drainOnce()
        #expect(report.succeeded == 1)
        #expect(try await h.sentOnGmail().count == 1)
        #expect(try h.store.operation(receipt.sendOperationID)?.status == .succeeded)
        #expect(await h.gmail.callCount(.sendDraft) == 2)
    }

    @Test func ambiguousFailureAfterCommitSendsExactlyOnce() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let events = EventLog()
        let drainer = h.drainer(api: h.gmail, events: events)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        await h.gmail.ambiguousFailureAfterCommit(.sendDraft)
        h.advancePast(receipt)
        let report = await drainer.drainOnce()
        #expect(report.succeeded == 2)
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        let sent = try await h.sentOnGmail()
        #expect(sent.count == 1)
        #expect(try h.draft(id).state == .sent)
        #expect(events.sent.first?.1?.rawValue == sent.first)
        #expect(try h.store.message(account: h.account, gmailMessageID: GmailMessageID(sent[0])) != nil)
        h.instant.advance(by: .seconds(600))
        #expect(await drainer.drainOnce().claimed == 0)
        #expect(await h.gmail.callCount(.sendDraft) == 1)
    }

    @Test func ambiguousFailureBeforeCommitRetriesAndSendsOnce() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        await h.gmail.failNext(.sendDraft, with: .transport(.timedOut))
        h.advancePast(receipt)
        let report = await drainer.drainOnce()
        #expect(report.retried == 1)
        let op = try #require(try h.store.operation(receipt.sendOperationID))
        #expect(op.status == .pending && op.attempts == 1)
        #expect(try h.draft(id).state == .sending)
        #expect(try !h.store.cancelSend(receipt))
        #expect(try await h.sentOnGmail().isEmpty)
        h.instant.advance(by: OperationDrainer.backoff(attempts: 0))
        #expect(await drainer.drainOnce().succeeded == 1)
        #expect(try await h.sentOnGmail().count == 1)
        #expect(await h.gmail.callCount(.sendDraft) == 2)
        #expect(await h.gmail.callCount(.getDraft) == 2)
    }

    @Test func aFailedCheckRecordsTheAttemptAndLooksAgainBeforeEverResending() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        await h.gmail.ambiguousFailureAfterCommit(.sendDraft)
        await h.gmail.failNext(.getDraft, with: .transport(.notConnected))
        h.advancePast(receipt)
        let report = await drainer.drainOnce()
        #expect(report.retried == 1)
        var op = try #require(try h.store.operation(receipt.sendOperationID))
        #expect(op.attempts == 1 && op.lastErrorCode == "send_unconfirmed")
        #expect(try !h.store.cancelSend(receipt))
        await h.gmail.failNext(.getDraft, with: .transport(.notConnected))
        h.instant.advance(by: OperationDrainer.unconfirmedRetry)
        #expect(await drainer.drainOnce().released == 1)
        op = try #require(try h.store.operation(receipt.sendOperationID))
        #expect(op.status == .pending && op.attempts == 1)
        h.instant.advance(by: OperationDrainer.unconfirmedRetry)
        #expect(await drainer.drainOnce().succeeded == 1)
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        #expect(try await h.sentOnGmail().count == 1)
        #expect(try h.draft(id).state == .sent)
    }

    @Test func aCopyThatCannotBeFoundEndsAsSentAfterAFewLooks() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let events = EventLog()
        let probe = ProbeGmail(h.gmail)
        probe.hideSentLookups(true)
        let applied = Counter()
        let drainer = h.drainer(api: probe, events: events, applied: applied)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        await h.gmail.ambiguousFailureAfterCommit(.sendDraft)
        h.advancePast(receipt)
        await drainer.drainOnce()
        let appliedSoFar = applied.current
        var looks = 0
        while try h.store.operation(receipt.sendOperationID)?.status == .pending, looks < 10 {
            h.instant.advance(by: OperationDrainer.unconfirmedRetry)
            await drainer.drainOnce()
            looks += 1
        }
        let op = try #require(try h.store.operation(receipt.sendOperationID))
        #expect(op.status == .cancelled && op.lastErrorCode == "target_gone")
        #expect(op.attempts == OperationDrainer.maxSendAttempts - 1)
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        #expect(try await h.sentOnGmail().count == 1)
        #expect(events.sent.map(\.0) == [id] && events.sent.first?.1 == nil)
        #expect(events.sendFailures.isEmpty)
        #expect(try h.draft(id).state == .discarded)
        #expect(applied.current == appliedSoFar + 1)
    }

    @Test func invalidRecipientFailsTheDraftAndReopensIt() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let events = EventLog()
        let drainer = h.drainer(api: h.gmail, events: events)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        await h.gmail.failNext(.sendDraft, with: .badRequest(reason: "invalidArgument", message: "Invalid To header"))
        h.advancePast(receipt)
        let report = await drainer.drainOnce()
        #expect(report.failed == 1)
        let draft = try h.draft(id)
        #expect(draft.state == .failed && draft.lastError == "Invalid To header")
        #expect(try h.store.operation(receipt.sendOperationID)?.lastErrorCode == "bad_request")
        #expect(events.sendFailures.map(\.0) == [id] && events.failedOperations.isEmpty)
        #expect(try await h.sentOnGmail().isEmpty)
        _ = try h.store.updateDraft(id, content: DraftContent(to: [EmailAddress(email: "carol@example.com")], cc: [], bcc: [],
                                                              subject: "Synthetic draft", bodyHTML: "<p>Fixed</p>",
                                                              attachments: []), expectedVersion: nil)
        let again = try h.store.send(id, undoWindow: .zero, origin: .app)
        h.advancePast(again)
        await drainer.drainOnce()
        #expect(try await h.sentOnGmail().count == 1)
        #expect(await h.gmail.callCount(.updateDraft) == 1)
    }

    @Test func aDraftConsumedBetweenTheCheckAndTheSendCountsAsSent() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let events = EventLog()
        let probe = ProbeGmail(h.gmail)
        let drainer = h.drainer(api: probe, events: events)
        let draft = try h.newDraft()
        let gmailID = try #require(try await h.upload(draft, drainer: drainer).gmailDraftID).rawValue
        await h.gmail.failNext(.sendDraft, with: .transport(.timedOut))
        let receipt = try h.store.send(draft, undoWindow: .zero, origin: .app)
        h.advancePast(receipt)
        #expect(await drainer.drainOnce().retried == 1)
        h.instant.advance(by: OperationDrainer.backoff(attempts: 0))
        let gate = probe.pauseNext(.sendDraft)
        let pass = Task { await drainer.drainOnce() }
        try await eventually("send #2 held after the existence check") { gate.reached }
        _ = try await h.gmail.sendDraft(id: gmailID)
        gate.open()
        let report = await pass.value
        #expect(report.succeeded == 1 && report.failed == 0)
        #expect(try h.draft(draft).state == .sent)
        #expect(try await h.sentOnGmail().count == 1)
        #expect(events.sent.map(\.0) == [draft] && events.sendFailures.isEmpty)
        #expect(try h.store.operation(receipt.sendOperationID)?.status == .succeeded)
    }

    @Test func aDraftSentElsewhereInsideTheWindowCountsAsSentNotAsFailed() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let events = EventLog()
        let drainer = h.drainer(api: h.gmail, events: events)
        let draft = try h.newDraft()
        let gmailID = try #require(try await h.upload(draft, drainer: drainer).gmailDraftID).rawValue
        let receipt = try h.store.send(draft, undoWindow: .seconds(10), origin: .app)
        _ = try await h.gmail.sendDraft(id: gmailID)
        h.advancePast(receipt)
        #expect(await drainer.drainOnce().succeeded == 1)
        #expect(try h.draft(draft).state == .sent)
        #expect(try await h.sentOnGmail().count == 1)
        #expect(events.sent.map(\.0) == [draft] && events.sendFailures.isEmpty)
        #expect(await h.gmail.callCount(.sendDraft) == 2)
    }

    @Test func aDraftDeletedElsewhereIsNotSentAndReopensForTheUser() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let events = EventLog()
        let drainer = h.drainer(api: h.gmail, events: events)
        let id = try h.newDraft()
        let uploaded = try await h.upload(id, drainer: drainer)
        let receipt = try h.store.send(id, undoWindow: .seconds(10), origin: .app)
        try await h.gmail.deleteDraft(id: try #require(uploaded.gmailDraftID).rawValue)
        h.advancePast(receipt)
        await drainer.drainOnce()
        #expect(try h.draft(id).state == .failed)
        #expect(events.sendFailures.map(\.0) == [id])
        #expect(try await h.sentOnGmail().isEmpty)
    }

    @Test func bccReachesGmailButNoRecipientCopy() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: try h.client)
        let id = try h.newDraft(to: ["bob@example.com"], cc: ["carol@example.com"], bcc: ["dave@example.com"])
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        h.advancePast(receipt)
        await drainer.drainOnce()
        let upload = try #require(h.uploads().first)
        #expect(lines(upload.raw, startingWith: "bcc:") == ["Bcc: dave@example.com"])
        let deliveries = await h.gmail.deliveries()
        #expect(Set(deliveries.map(\.recipient)) == ["bob@example.com", "carol@example.com", "dave@example.com"])
        for delivery in deliveries {
            #expect(lines(String(decoding: delivery.raw, as: UTF8.self), startingWith: "bcc:").isEmpty)
        }
        let sent = try #require(try await h.sentOnGmail().first)
        #expect(lines(try await h.rawOnGmail(sent), startingWith: "bcc:").count == 1)
    }

    @Test func aReplyGoesIntoItsThreadWithThreadingHeaders() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let thread = h.threads[0]
        let original = try #require(await h.gmail.messageIDs(inThread: thread).first)
        let originalID = "<\(original)@fake.openhuman.invalid>"
        let id = try h.newDraft(subject: "Re: Seeded thread 0", headers: ["In-Reply-To": originalID, "References": originalID],
                                mode: .reply, replyTo: GmailMessageID(original))
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        h.advancePast(receipt)
        await drainer.drainOnce()
        let sent = try #require(try await h.sentOnGmail().first)
        #expect(await h.gmail.messageIDs(inThread: thread).contains(sent))
        let raw = try await h.rawOnGmail(sent)
        #expect(lines(raw, startingWith: "in-reply-to:") == ["In-Reply-To: \(originalID)"])
        #expect(lines(raw, startingWith: "references:") == ["References: \(originalID)"])
        #expect(try h.draft(id).thread?.gmailThreadID.rawValue == thread)
        #expect(try h.store.thread(try h.ref(thread))?.messageCount == 2)
    }

    @Test func stoppingMidSendRecordsTheAttemptAndTheNextOwnerChecksFirst() async throws {
        let clock = TestClock(now: Date())
        let h = try await WriteHarness(clock: clock)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        await h.gmail.latency(.sendDraft, .seconds(5))
        let first = h.drainer(api: h.gmail)
        clock.advance(to: receipt.sendAfter.addingTimeInterval(1))
        let pass = Task { await first.drainOnce() }
        try await eventually("send in flight") {
            let calls = await h.gmail.callCount(.sendDraft)
            return calls == 1 && clock.sleeperCount == 1
        }
        pass.cancel()
        _ = await pass.value
        let op = try #require(try h.store.operation(receipt.sendOperationID))
        #expect(op.status == .pending && op.attempts == 1)
        await h.gmail.latency(.sendDraft, .zero)
        let next = h.drainer(api: h.gmail)
        #expect(await next.drainOnce().succeeded == 1)
        #expect(try await h.sentOnGmail().count == 1)
        #expect(await h.gmail.callCount(.getDraft) == 1)
    }
}
