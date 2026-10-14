import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct MarkerAndScheduleTests {
    static let agentHeaders = ["X-OpenHuman-Origin": "cli"]

    static func content(_ text: String) -> DraftContent {
        DraftContent(to: [EmailAddress(email: "bob@example.com")], cc: [], bcc: [], subject: "Synthetic draft",
                     bodyHTML: "<p>\(text)</p>", attachments: [])
    }

    @Test func anAgentDraftKeepsItsMarkersUntilTheUserSendsItAndNoRecipientSeesThem() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: try h.client, external: true)
        let id = try h.newDraft(origin: .cli, review: .pending, headers: Self.agentHeaders)
        var draft = try await h.upload(id, drainer: drainer)
        let first = try #require(draft.gmailMessageID)
        #expect(lines(h.uploads()[0].raw, startingWith: "x-openhuman-origin:") == ["X-OpenHuman-Origin: cli"])
        #expect(await h.labelNames(ofMessage: first.rawValue).contains(OHGmailLabels.agent))

        _ = try h.store.updateAgentDraft(id, content: Self.content("Second take"), agentNote: "again")
        draft = try await h.upload(id, drainer: drainer)
        let second = try #require(draft.gmailMessageID)
        #expect(second != first && draft.reviewState == .pending)
        #expect(await h.labelNames(ofMessage: second.rawValue).contains(OHGmailLabels.agent))
        #expect(await h.gmail.labelIDs(ofMessage: first.rawValue) == nil)

        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        h.advancePast(receipt)
        await drainer.drainOnce()
        let requests = h.wire.requests
        let sendAt = try #require(requests.firstIndex { $0.url.path() == "/gmail/v1/users/me/drafts/send" })
        let finalUpload = try #require(requests[..<sendAt].last { $0.url.path().hasPrefix("/upload/gmail/v1/users/me/drafts") })
        #expect(finalUpload.method == "PUT")
        #expect(lines(String(decoding: finalUpload.body ?? Data(), as: UTF8.self), startingWith: "x-openhuman-").isEmpty)
        let deliveries = await h.gmail.deliveries()
        #expect(!deliveries.isEmpty)
        for delivery in deliveries {
            #expect(lines(String(decoding: delivery.raw, as: UTF8.self), startingWith: "x-openhuman-").isEmpty)
        }
        let sent = try #require(try await h.sentOnGmail().first)
        #expect(!(await h.labelNames(ofMessage: sent)).contains(OHGmailLabels.agent))
        #expect(lines(try await h.rawOnGmail(sent), startingWith: "x-openhuman-").isEmpty)
        draft = try h.draft(id)
        #expect(draft.state == .sent && draft.origin == .cli)
        #expect(draft.extraHeaders["X-OpenHuman-Origin"] == "cli")
    }

    @Test func anAmbiguousStripStillSendsOnceAndCleanly() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let probe = ProbeGmail(h.gmail)
        let drainer = h.drainer(api: probe, external: true)
        let id = try h.newDraft(origin: .cli, review: .pending, headers: Self.agentHeaders)
        try await h.upload(id, drainer: drainer)
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        await h.gmail.ambiguousFailureAfterCommit(.updateDraft)
        h.advancePast(receipt)
        #expect(await drainer.drainOnce().retried == 1)
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        h.instant.advance(by: OperationDrainer.backoff(attempts: 0))
        await drainer.drainOnce()
        #expect(try await h.sentOnGmail().count == 1)
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        let finalUpload = try #require(probe.lastUploadBeforeSend)
        #expect(lines(finalUpload, startingWith: "x-openhuman-").isEmpty)
        for delivery in await h.gmail.deliveries() {
            #expect(lines(String(decoding: delivery.raw, as: UTF8.self), startingWith: "x-openhuman-").isEmpty)
        }
        let sent = try #require(try await h.sentOnGmail().first)
        #expect(!(await h.labelNames(ofMessage: sent)).contains(OHGmailLabels.agent))
        #expect(try h.draft(id).origin == .cli && h.draft(id).state == .sent)
    }

    @Test func approvingAnAgentDraftDropsBothMarkersOnTheNextUpload() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail, external: true)
        let id = try h.newDraft(origin: .agent, review: .pending, headers: ["X-OpenHuman-Origin": "agent"])
        try await h.upload(id, drainer: drainer)
        try h.store.setReviewState(id, .approved)
        await drainer.drainOnce()
        let draft = try h.draft(id)
        let message = try #require(draft.gmailMessageID)
        #expect(!(await h.labelNames(ofMessage: message.rawValue)).contains(OHGmailLabels.agent))
        #expect(lines(try await h.rawOnGmail(message.rawValue), startingWith: "x-openhuman-").isEmpty)
        #expect(try h.ops([.pending, .inFlight, .failed]).isEmpty)
    }

    @Test func aScheduledDraftCarriesTheHeaderAndHiddenStampAndARescheduleSwapsIt() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let id = try h.newDraft()
        let t1 = ScheduleStamp.floorToMinute(Date().addingTimeInterval(86_400))
        try h.store.scheduleSend(id, at: t1)
        await drainer.drainOnce()
        var draft = try h.draft(id)
        #expect(draft.state == .scheduled && !draft.isDirty)
        let m1 = try #require(draft.gmailMessageID).rawValue
        let stamp1 = ScheduleLabel(kind: .scheduled, due: t1).name
        #expect(await h.labelNames(ofMessage: m1).isSuperset(of: [OHGmailLabels.scheduled, stamp1]))
        #expect(lines(try await h.rawOnGmail(m1), startingWith: "x-openhuman-send-at:")
                == ["X-OpenHuman-Send-At: \(ScheduleStamp.format(t1))"])
        let stampLabel = try await h.gmail.getLabel(id: try #require(await h.gmail.labelID(named: stamp1)))
        #expect(stampLabel.labelListVisibility == "labelHide" && stampLabel.messageListVisibility == "hide")
        let marker = try await h.gmail.getLabel(id: try #require(await h.gmail.labelID(named: OHGmailLabels.scheduled)))
        #expect(marker.labelListVisibility == "labelShow" && marker.messageListVisibility == "hide")

        let t2 = t1.addingTimeInterval(3_600)
        try h.store.scheduleSend(id, at: t2)
        await drainer.drainOnce()
        draft = try h.draft(id)
        let m2 = try #require(draft.gmailMessageID).rawValue
        let labels2 = await h.labelNames(ofMessage: m2)
        #expect(labels2.contains(ScheduleLabel(kind: .scheduled, due: t2).name) && !labels2.contains(stamp1))
        #expect(labels2.contains(OHGmailLabels.scheduled))

        try h.store.cancelScheduledSend(id)
        await drainer.drainOnce()
        draft = try h.draft(id)
        let m3 = try #require(draft.gmailMessageID).rawValue
        #expect(draft.state == .editing)
        #expect(!(await h.labelNames(ofMessage: m3)).contains { DraftMessage.isMarkerLabel($0) })
        #expect(lines(try await h.rawOnGmail(m3), startingWith: "x-openhuman-").isEmpty)
    }

    @Test func aSendLaterSendStripsTheScheduleBeforeSending() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: try h.client)
        let id = try await scheduledDraft(h, drainer: drainer)
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .scheduler)
        h.advancePast(receipt)
        await drainer.drainOnce()
        let sent = try #require(try await h.sentOnGmail().first)
        #expect(try await h.sentOnGmail().count == 1)
        #expect(lines(try await h.rawOnGmail(sent), startingWith: "x-openhuman-").isEmpty)
        #expect(!(await h.labelNames(ofMessage: sent)).contains { DraftMessage.isMarkerLabel($0) })
        for delivery in await h.gmail.deliveries() {
            #expect(lines(String(decoding: delivery.raw, as: UTF8.self), startingWith: "x-openhuman-").isEmpty)
        }
        #expect(try h.draft(id).state == .sent)
    }

    @Test func aSendLaterDraftAnotherInstallSentFirstIsNeverSentTwice() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let events = EventLog()
        let drainer = h.drainer(api: h.gmail, events: events)
        let id = try await scheduledDraft(h, drainer: drainer)
        let gmailDraft = try #require(try h.draft(id).gmailDraftID).rawValue
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .scheduler)
        _ = try await h.gmail.sendDraft(id: gmailDraft)
        h.advancePast(receipt)
        await drainer.drainOnce()
        let op = try #require(try h.store.operation(receipt.sendOperationID))
        #expect(op.status == .cancelled && op.lastErrorCode == "target_gone")
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        #expect(try await h.sentOnGmail().count == 1)
        #expect(try h.draft(id).state == .discarded)
        #expect(events.sendFailures.isEmpty && events.failedOperations.isEmpty)
    }

    @Test func aSendLaterDraftSentByAnotherInstallBetweenStripAndSendIsNotSentAgain() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let probe = ProbeGmail(h.gmail)
        let drainer = h.drainer(api: probe)
        let id = try await scheduledDraft(h, drainer: drainer)
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .scheduler)
        probe.afterNextUpdate { gmail, draft in _ = try? await gmail.sendDraft(id: draft.id) }
        h.advancePast(receipt)
        await drainer.drainOnce()
        #expect(try h.store.operation(receipt.sendOperationID)?.lastErrorCode == "target_gone")
        #expect(try await h.sentOnGmail().count == 1)
        #expect(await h.gmail.callCount(.sendDraft) == 2)
    }

    @Test func aStaleSendLaterOpIsHandedBackToTheRunnerWithoutTouchingGmail() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let id = try await scheduledDraft(h, drainer: drainer)
        let calls = await h.gmail.callLog.count
        let stale = try h.store.send(id, undoWindow: .zero, origin: .scheduler)
        h.instant.advance(by: .seconds(300))
        let report = await drainer.drainOnce()
        #expect(report.cancelled == 1 && report.failed == 0)
        #expect(try h.store.operation(stale.sendOperationID)?.lastErrorCode == "stale_schedule")
        #expect(try h.draft(id).state == .scheduled)
        #expect(await h.gmail.callLog.count == calls)
    }

    @Test func aSchedulerOpQueuedAfterTheDrainersClockMovedAheadIsFresh() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = OperationDrainer(account: h.account, store: h.store, api: h.gmail, clock: h.clock, ownerID: "test-owner")
        let id = try await scheduledDraft(h, drainer: drainer)
        h.instant.advance(by: .seconds(600))
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .scheduler)
        let report = await drainer.drainOnce()
        #expect(report.cancelled == 0 && report.succeeded == 1)
        #expect(try h.store.operation(receipt.sendOperationID)?.status == .succeeded)
        #expect(try await h.sentOnGmail().count == 1)
        #expect(try h.draft(id).state == .sent)
    }

    @Test func aSendLaterOpThatAlreadyStrippedItsMarkersIsNeverStale() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let id = try await scheduledDraft(h, drainer: drainer)
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .scheduler)
        await h.gmail.failNext(.sendDraft, with: .transport(.notConnected))
        h.advancePast(receipt)
        await drainer.drainOnce()
        let op = try #require(try h.store.operation(receipt.sendOperationID))
        #expect(op.status == .pending && op.attempts == 1 && op.lastErrorCode == "released_after_strip")
        h.instant.advance(by: .seconds(300))
        await drainer.drainOnce()
        #expect(try await h.sentOnGmail().count == 1)
        #expect(try h.draft(id).state == .sent)
    }

    @Test func aFiredRemindersInboxMoveIsNeverStale() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let ref = try h.ref(h.threads[0])
        _ = try h.store.apply(.archive([ref]), origin: .app)
        await drainer.drainOnce()
        _ = try h.store.apply(.setReminder(ref, dueAt: h.clock.now, condition: .always), origin: .app)
        let reminder = try #require(try h.store.activeReminders(account: h.account, limit: 10).first)
        let fired = try #require(try h.store.fireReminder(reminder.reminder.id, now: h.clock.now, satisfied: false))
        h.instant.advance(by: .seconds(600))
        #expect(await drainer.drainOnce().succeeded == 1)
        #expect(try h.store.operation(fired.operationIDs[0])?.status == .succeeded)
        #expect((await h.serverLabels(ofThread: h.threads[0])).contains("INBOX"))
    }

    @Test func staleRuleCoversSchedulerOpsOnly() async throws {
        let clock = InstantClock(now: Date())
        let h = try await WriteHarness(clock: clock)
        let drainer = h.drainer(api: h.gmail)
        let old = clock.now.addingTimeInterval(-180)
        func op(_ payload: OperationPayload, _ origin: OperationOrigin, attempts: Int = 0) -> OperationItem {
            OperationItem(id: OperationID(rawValue: 1), accountID: h.account, kind: .modifyLabels, payload: payload,
                          status: .inFlight, attempts: attempts, notBefore: old, nextRetryAt: old, origin: origin,
                          createdAt: old, updatedAt: old)
        }
        let wake = OperationPayload.modifyLabels(ids: [], add: [GmailLabelID("INBOX")], remove: [GmailLabelID("Label_9")],
                                                 addNames: [])
        let reminder = OperationPayload.modifyLabels(ids: [], add: [GmailLabelID("INBOX")], remove: [], addNames: [])
        let send = OperationPayload.sendDraft(draftID: DraftID("d"))
        #expect(await drainer.isStale(op(wake, .scheduler)))
        #expect(await !drainer.isStale(op(wake, .app)))
        #expect(await !drainer.isStale(op(reminder, .scheduler)))
        #expect(await drainer.isStale(op(send, .scheduler)))
        #expect(await !drainer.isStale(op(send, .scheduler, attempts: 1)))
        #expect(await drainer.isStale(op(.createLabel(name: "OpenHuman/Snoozed/20261012T0900Z"), .scheduler)))
        var fresh = op(wake, .scheduler)
        fresh.createdAt = clock.now.addingTimeInterval(-60)
        #expect(await !drainer.isStale(fresh))
    }

    private func scheduledDraft(_ h: WriteHarness, drainer: OperationDrainer) async throws -> DraftID {
        let id = try h.newDraft()
        try h.store.scheduleSend(id, at: Date().addingTimeInterval(86_400))
        await drainer.drainOnce()
        let draft = try h.draft(id)
        #expect(draft.state == .scheduled && !draft.isDirty && draft.gmailDraftID != nil)
        return id
    }
}
