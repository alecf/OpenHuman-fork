import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct SendLaterRunnerTests {
    private func scheduleOnServer(_ h: EngineHarness, at sendAt: Date, origin: String? = nil) async throws -> String {
        let draft = try await h.gmail.createDraft(rawRFC822: rawDraft(sendAt: sendAt, origin: origin), threadID: nil)
        try await stampLabels(h, draft, at: sendAt)
        return draft.id
    }

    private func stampLabels(_ h: EngineHarness, _ draft: GmailDraft, at sendAt: Date) async throws {
        let stamp = ScheduleLabel(kind: .scheduled, due: sendAt).name
        var marker = await h.gmail.labelID(named: OHGmailLabels.scheduled)
        if marker == nil { marker = await h.gmail.addUserLabel(OHGmailLabels.scheduled) }
        var stampID = await h.gmail.labelID(named: stamp)
        if stampID == nil { stampID = await h.gmail.addUserLabel(stamp) }
        let message = try #require(draft.message?.id)
        await h.gmail.modifyLabels(messageID: message, add: [try #require(marker), try #require(stampID)])
    }

    private func sendOps(_ h: EngineHarness, _ draft: DraftID) throws -> [OperationItem] {
        try h.ops().filter { if case let .sendDraft(id) = $0.payload { return id == draft } else { return false } }
    }

    @Test func aDraftScheduledElsewhereIsQueuedOnceDuePlusJitter() async throws {
        let h = try await EngineHarness()
        let sendAt = h.clock.now.addingTimeInterval(600)
        let gmailDraft = try await scheduleOnServer(h, at: sendAt)
        let engine = h.engine()
        await engine.setTestSeams(jitter: .seconds(5))
        await engine.start()
        try await h.waitForSyncs(engine)
        let id = try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(gmailDraft)))
        #expect(try h.store.draft(id)?.state == .scheduled)
        #expect(try h.store.draft(id)?.sendAt == sendAt)
        let scheduler = try #require(await engine.scheduler(for: h.account))

        h.clock.advance(to: sendAt.addingTimeInterval(4))
        try await eventually("armed for due + jitter") { await scheduler.nextFire == sendAt.addingTimeInterval(5) }
        #expect(try sendOps(h, id).isEmpty)

        h.clock.advance(to: sendAt.addingTimeInterval(5))
        try await eventually("queued") { try !sendOps(h, id).isEmpty }
        let op = try #require(try sendOps(h, id).first)
        #expect(op.origin == .scheduler)
        #expect(op.dependsOn == nil)
        try await eventually("sent") { try h.store.operation(op.id)?.status == .succeeded }
        #expect(try h.store.draft(id)?.state == .sent)
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        try await h.expectOneCleanSentMessage()
        let passes = await scheduler.passes
        await scheduler.poke()
        try await eventually("another pass") {
            let idle = await scheduler.nextFire != nil
            return await scheduler.passes > passes && idle
        }
        #expect(try sendOps(h, id).count == 1)
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        #expect(await h.gmail.callCount(.sendMessage) == 0)
        await engine.stop()
    }

    @Test func anUnreviewedAgentDraftNeedsReviewAndAMissedOneNeedsConfirmation() async throws {
        let h = try await EngineHarness()
        let agent = try await scheduleOnServer(h, at: h.clock.now.addingTimeInterval(120), origin: "agent")
        let missed = try await scheduleOnServer(h, at: h.clock.now.addingTimeInterval(-2 * 86_400))
        let engine = h.engine()
        await engine.setTestSeams(jitter: .zero)
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        let agentID = try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(agent)))
        let missedID = try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(missed)))
        #expect(try h.store.draft(agentID)?.reviewState == .pending)

        try await eventually("missed") { try h.store.draft(missedID)?.state == .failed }
        #expect(try h.store.draft(missedID)?.lastError == "scheduled time passed while Mail was closed")
        h.clock.advance(by: .seconds(180))
        try await eventually("agent draft held") { try h.store.draft(agentID)?.state != .scheduled }
        #expect(try h.store.draft(agentID)?.lastError == "needs review")
        try await eventually("needs-confirmation events") { Set(events.needsConfirmation).isSuperset(of: [agentID, missedID]) }
        #expect(try sendOps(h, agentID).isEmpty && sendOps(h, missedID).isEmpty)
        await engine.stop()
    }

    @Test func aDraftCarryingOnlyTheSendAtHeaderNeedsConfirmationAndIsNeverSent() async throws {
        let h = try await EngineHarness()
        let sendAt = h.clock.now.addingTimeInterval(60)
        let planted = try await h.gmail.createDraft(rawRFC822: rawDraft(sendAt: sendAt), threadID: nil)
        let engine = h.engine()
        await engine.setTestSeams(jitter: .zero)
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        let id = try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(planted.id)))
        #expect(try h.store.draft(id)?.origin == .user)

        h.clock.advance(to: sendAt.addingTimeInterval(1))
        try await eventually("needs confirmation") { events.needsConfirmation.contains(id) }
        #expect(try h.store.draft(id)?.state == .failed)
        #expect(try h.store.draft(id)?.lastError == "scheduled outside OpenHuman")
        #expect(try sendOps(h, id).isEmpty)
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        #expect(await h.gmail.callCount(.sendMessage) == 0)
        await engine.stop()
    }

    @Test func aDraftEditedElsewhereIsRefreshedAndSentAtItsNewTimeWithItsNewBody() async throws {
        let h = try await EngineHarness()
        let sendAt = h.clock.now.addingTimeInterval(600)
        let gmailDraft = try await scheduleOnServer(h, at: sendAt)
        let engine = h.engine()
        await engine.setTestSeams(jitter: .seconds(5))
        await engine.start()
        try await h.waitForSyncs(engine)
        let id = try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(gmailDraft)))

        let later = sendAt.addingTimeInterval(600)
        let edited = try await h.gmail.updateDraft(id: gmailDraft, rawRFC822: rawDraft(body: "Edited elsewhere.", sendAt: later),
                                                   threadID: nil)
        try await stampLabels(h, edited, at: later)
        h.clock.advance(to: sendAt.addingTimeInterval(5))
        try await eventually("moved to the later time") { try h.store.draft(id)?.sendAt == later }
        #expect(try sendOps(h, id).isEmpty)
        #expect(try h.store.draft(id)?.content.bodyText?.contains("Edited elsewhere.") == true)

        h.clock.advance(to: later.addingTimeInterval(5))
        try await eventually("queued at the new time") { try sendOps(h, id).count == 1 }
        try await eventually("sent") { try sendOps(h, id).first?.status == .succeeded }
        try await h.expectOneCleanSentMessage()
        let sent = try #require(try await h.sentOnGmail().first)
        #expect(try await h.rawOnGmail(sent).contains("Edited elsewhere."))
        await engine.stop()
    }

    @Test func theResourceCheckStopsOnAMessageThisProcessHasNotReadOrAConsumedDraft() async throws {
        let h = try await EngineHarness()
        let syncer = AccountSyncer(account: h.account, store: h.store, api: h.gmail, clock: h.clock)
        try await syncer.sync(reason: "test")
        let sendAt = h.clock.now.addingTimeInterval(60)
        let gmailDraft = try await scheduleOnServer(h, at: sendAt)
        try await syncer.refreshDrafts()
        let row = try #require(try h.store.draft(account: h.account, gmailDraftID: GmailDraftID(gmailDraft)))
        let context = RunnerContext(account: h.account, store: h.store, syncer: syncer, api: h.gmail, clock: h.clock,
                                    jitter: .zero, emit: { _ in }, pokeDrainer: {}, isReachable: { true },
                                    labelsFreshness: LabelsFreshness())
        let preflight = ScheduleGuard(context)
        #expect(try await preflight.confirmScheduledSend(row) == .proceed)

        let edited = try await h.gmail.updateDraft(id: gmailDraft, rawRFC822: rawDraft(body: "Edited.", sendAt: sendAt), threadID: nil)
        try await stampLabels(h, edited, at: sendAt)
        #expect(try await preflight.confirmScheduledSend(row) == .stop("edited elsewhere"))
        let refreshed = try #require(try h.store.draft(row.id))
        #expect(try await preflight.confirmScheduledSend(refreshed) == .proceed)

        _ = try await h.gmail.updateDraft(id: gmailDraft, rawRFC822: rawDraft(sendAt: sendAt.addingTimeInterval(60)),
                                          threadID: nil)
        #expect(try await preflight.confirmScheduledSend(refreshed) == .stop("schedule changed elsewhere"))

        try await h.gmail.deleteDraft(id: gmailDraft)
        #expect(try await preflight.confirmScheduledSend(refreshed) == .stop("consumed elsewhere"))
    }

    @Test func writeAllowlistNeverRunsSendLater() async throws {
        let h = try await EngineHarness(safeMode: .writeAllowlist, stack: true)
        defer { h.cleanup() }
        let engine = h.engine(safeMode: .writeAllowlist)
        await engine.start()
        try await h.waitForSyncs(engine)
        #expect(!(await engine.scheduler(for: h.account)?.kinds ?? []).contains(.sendLater))
        await engine.stop()
    }
}
