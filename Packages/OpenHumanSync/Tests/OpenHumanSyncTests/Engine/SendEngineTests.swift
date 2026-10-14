import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct SendEngineTests {
    private func syncedDraft(_ h: EngineHarness, engine: MailEngine) async throws -> DraftID {
        let remote = try await h.gmail.createDraft(rawRFC822: rawDraft(subject: "Synthetic send"), threadID: nil)
        return try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(remote.id)))
    }

    private func expectSentOnce(_ h: EngineHarness, _ receipt: SendReceipt) async throws {
        try await eventually("sent") { try h.store.operation(receipt.sendOperationID)?.status == .succeeded }
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        #expect(await h.gmail.callCount(.sendMessage) == 0)
        #expect(try h.store.draft(receipt.draftID)?.state == .sent)
        try await h.expectOneCleanSentMessage()
    }

    @Test func aStoredUndoWindowOutsideTheSettingsRangeIsClampedWhenSending() async throws {
        #expect(MailEngine.undoWindow(storedSeconds: Int.max) == .seconds(60))
        #expect(MailEngine.undoWindow(storedSeconds: 61) == .seconds(60))
        #expect(MailEngine.undoWindow(storedSeconds: 10) == .seconds(10))
        #expect(MailEngine.undoWindow(storedSeconds: -5) == .zero)
        #expect(MailEngine.undoWindow(storedSeconds: Int.min) == .zero)
        let h = try await EngineHarness(threads: 0)
        let engine = h.engine()
        try h.store.setSetting(.undoSendSeconds, Int.max, scope: .global)
        let draft = try await engine.newDraft(account: h.account, mode: .new, replyTo: nil, origin: .user)
        let before = Date()
        let held = try await engine.send(draft.id, authorization: .userConfirmed, undoWindow: nil)
        #expect(held.sendAfter >= before.addingTimeInterval(59) && held.sendAfter < before.addingTimeInterval(86_000))
    }

    @Test func undoInsideTheWindowCancelsAndASendAfterTheWindowGoesOutOnce() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let draft = try await syncedDraft(h, engine: engine)
        let undone = try await engine.send(draft, authorization: .userConfirmed, undoWindow: .seconds(10))
        #expect(undone.upsertOperationID == nil)
        #expect(try h.store.draft(draft)?.state == .sending)
        #expect(try await engine.cancelSend(undone))
        #expect(try h.store.draft(draft)?.state == .editing)
        #expect(try h.store.operation(undone.sendOperationID)?.status == .cancelled)
        h.clock.advance(by: .seconds(60))
        try await h.waitForSyncs(engine, 2)
        #expect(await h.gmail.callCount(.sendDraft) == 0)

        let receipt = try await engine.send(draft, authorization: .userConfirmed, undoWindow: .seconds(10))
        h.advancePast(receipt)
        try await expectSentOnce(h, receipt)
        #expect(!(try await engine.cancelSend(receipt)))
        await engine.stop()
    }

    @Test func launchReconcileTurnsAnUncommittedSendOverAnHourOldBackIntoADraft() async throws {
        let h = try await EngineHarness()
        let first = h.engine()
        await first.start()
        try await h.waitForSyncs(first)
        let draft = try await syncedDraft(h, engine: first)
        await first.stop()
        let receipt = try h.store.send(draft, undoWindow: .seconds(10), origin: .app)
        h.clock.advance(by: .seconds(7_200))
        let engine = h.engine()
        let events = EngineEvents(engine)
        await engine.start()
        try await eventually("interrupted") { events.interruptedSends == [draft] }
        #expect(try h.store.draft(draft)?.state == .editing)
        #expect(try h.store.operation(receipt.sendOperationID)?.status == .cancelled)
        try await h.waitForSyncs(engine)
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        await engine.stop()
    }

    @Test func aYoungerUncommittedSendIsNotTouchedByTheLaunchReconcileAndGoesOutOnce() async throws {
        let h = try await EngineHarness()
        let first = h.engine()
        await first.start()
        try await h.waitForSyncs(first)
        let draft = try await syncedDraft(h, engine: first)
        await first.stop()
        let receipt = try h.store.send(draft, undoWindow: .seconds(10), origin: .app)
        h.clock.advance(by: .seconds(1_800))
        let engine = h.engine()
        let events = EngineEvents(engine)
        await engine.start()
        try await expectSentOnce(h, receipt)
        #expect(events.interruptedSends.isEmpty)
        try await eventually("sent event") { events.sent == [draft] }
        await engine.stop()
    }

    @Test func theQuitFlushCommitsPendingSendsWithinItsDeadlineAndTheyGoOutOnce() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let draft = try await syncedDraft(h, engine: engine)
        let receipt = try await engine.send(draft, authorization: .userConfirmed, undoWindow: .seconds(600))
        h.clock.advance(by: .seconds(120))
        try await h.waitForSyncs(engine, 2)
        #expect(try h.store.operation(receipt.sendOperationID)?.status == .pending)
        await engine.flushPendingSends(deadline: .seconds(20))
        #expect(try h.store.operation(receipt.sendOperationID)?.status != .pending)
        #expect(!(try await engine.cancelSend(receipt)))
        try await expectSentOnce(h, receipt)
        await engine.stop()
    }

    @Test func sendNowAndScheduleSendAreTheAppsInNormalModeOnly() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let draft = try await syncedDraft(h, engine: engine)
        try await engine.scheduleSend(draft, at: h.clock.now.addingTimeInterval(3_600))
        #expect(try h.store.draft(draft)?.state == .scheduled)
        try await engine.cancelScheduledSend(draft)
        #expect(try h.store.draft(draft)?.state == .editing)
        await #expect(throws: StoreError.self) { try await engine.scheduleSend(draft, at: h.clock.now.addingTimeInterval(-60)) }
        #expect(try h.store.draft(draft)?.state == .editing)
        let clean = try await syncedDraft(h, engine: engine)
        let receipt = try await engine.send(clean, authorization: .userConfirmed, undoWindow: .seconds(600))
        h.clock.advance(by: .seconds(120))
        #expect(try await engine.sendNow(receipt))
        try await expectSentOnce(h, receipt)
        await engine.stop()
    }

    @Test(arguments: [false, true])
    func anAgentDraftTheUserSendsReachesNobodyWithItsMarkers(ambiguousStrip: Bool) async throws {
        let h = try await EngineHarness()
        let probe = ProbeGmail(h.gmail)
        let app = h.engine(factory: FixedGmailFactory(api: probe))
        let events = EngineEvents(app)
        await app.setDrainsExternalOpsForTesting(true)
        await app.start()
        try await h.waitForSyncs(app)
        let cli = h.engine(role: .localClient, factory: .some(nil))
        var content = DraftContent(to: [EmailAddress(email: "bob@example.invalid")], cc: [], bcc: [],
                                   subject: "From an agent", bodyHTML: "<p>Synthetic first pass.</p>", attachments: [])
        let id = try await cli.createAgentDraft(account: h.account, mode: .new, replyTo: nil, content: content,
                                                note: "for review", origin: .cli)
        func uploaded(replacing previous: GmailMessageID?) async throws -> String {
            try await eventually("uploaded by the app's drainer") {
                let message = try h.store.draft(id)?.gmailMessageID, idle = try h.ops([.pending, .inFlight]).isEmpty
                return message != nil && message != previous && idle
            }
            return try #require(try h.store.draft(id)?.gmailMessageID).rawValue
        }
        let first = try await uploaded(replacing: nil)
        #expect(await h.labelNames(ofMessage: first).contains(OHGmailLabels.agent))
        #expect(lines(try await h.rawOnGmail(first), startingWith: "x-openhuman-origin:") == ["X-OpenHuman-Origin: cli"])

        content.bodyHTML = "<p>Synthetic second pass.</p>"
        try await cli.updateAgentDraft(id, content: content, note: nil)
        let second = try await uploaded(replacing: GmailMessageID(first))
        #expect(await h.labelNames(ofMessage: second).contains(OHGmailLabels.agent))
        #expect(await h.gmail.labelIDs(ofMessage: first) == nil)

        if ambiguousStrip { await h.gmail.ambiguousFailureAfterCommit(.updateDraft) }
        let receipt = try await app.send(id, authorization: .userConfirmed, undoWindow: .zero)
        h.advancePast(receipt)
        if ambiguousStrip {
            try await eventually("3a retried after its backoff") {
                try h.store.operation(receipt.sendOperationID)?.attempts == 1
            }
            #expect(await h.gmail.callCount(.sendDraft) == 0)
            h.clock.advance(by: OperationDrainer.backoff(attempts: 0))
        }
        try await expectSentOnce(h, receipt)
        #expect(lines(try #require(probe.lastUploadBeforeSend), startingWith: "x-openhuman-").isEmpty)
        let draft = try #require(try h.store.draft(id))
        #expect(draft.origin == .cli && draft.extraHeaders["X-OpenHuman-Origin"] == "cli")
        try await eventually("sent event") { events.sent == [id] }
        #expect(events.sendFailures.isEmpty)
        await app.stop()
    }
}
