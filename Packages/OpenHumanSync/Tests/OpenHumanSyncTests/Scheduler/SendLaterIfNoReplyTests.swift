import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct SendLaterIfNoReplyTests {
    private func scheduleReply(_ h: EngineHarness, thread: String, condition: String, at sendAt: Date) async throws -> String {
        var raw = String(decoding: rawDraft(subject: "Re: Synthetic plan", sendAt: sendAt), as: UTF8.self)
        raw = raw.replacingOccurrences(of: "MIME-Version: 1.0",
                                       with: "\(OHGmailLabels.sendAtConditionHeader): \(condition)\r\nMIME-Version: 1.0")
        let draft = try await h.gmail.createDraft(rawRFC822: Data(raw.utf8), threadID: thread)
        let stamp = ScheduleLabel(kind: .scheduled, due: sendAt).name
        var marker = await h.gmail.labelID(named: OHGmailLabels.scheduled)
        if marker == nil { marker = await h.gmail.addUserLabel(OHGmailLabels.scheduled) }
        var stampID = await h.gmail.labelID(named: stamp)
        if stampID == nil { stampID = await h.gmail.addUserLabel(stamp) }
        await h.gmail.modifyLabels(messageID: try #require(draft.message?.id),
                                   add: [try #require(marker), try #require(stampID)])
        return draft.id
    }

    private func sendOps(_ h: EngineHarness, _ draft: DraftID) throws -> [OperationItem] {
        try h.ops().filter { if case let .sendDraft(id) = $0.payload { return id == draft } else { return false } }
    }

    @Test func aReplyFromSomeoneElseBeforeTheDueTimeCancelsTheSendAndKeepsTheDraft() async throws {
        let h = try await EngineHarness()
        let first = await h.gmail.deliver(subject: "Synthetic plan", body: "Synthetic question.")
        let sendAt = h.clock.now.addingTimeInterval(600)
        let condition = SendAtCondition(anchor: GmailMessageID(first.messageID)).headerValue
        let gmailDraft = try await scheduleReply(h, thread: first.threadID, condition: condition, at: sendAt)
        let engine = h.engine()
        await engine.setTestSeams(jitter: .zero)
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        let id = try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(gmailDraft)))
        #expect(try h.store.draft(id)?.state == .scheduled)
        #expect(try h.store.draft(id)?.thread != nil, "a reply in the synced conversation")

        await h.gmail.deliver(from: "Bob Example <bob@example.invalid>", subject: "Re: Synthetic plan",
                              body: "Synthetic answer.", threadID: first.threadID)
        h.clock.advance(to: sendAt.addingTimeInterval(1))
        try await eventually("cancelled") { try h.store.draft(id)?.state == .editing }
        try await eventually("the notice event") { events.cancelledByReply.contains(id) }
        #expect(try sendOps(h, id).isEmpty)
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        #expect(await h.gmail.callCount(.sendMessage) == 0)
        let headers = try #require(try h.store.draft(id)?.extraHeaders)
        #expect(!headers.keys.contains { $0.lowercased().hasPrefix("x-openhuman-send-at") }, "the schedule and its condition are gone")
        #expect(!events.needsConfirmation.contains(id))
        await engine.stop()
    }

    @Test func withoutAReplyTheSendGoesOutAsBefore() async throws {
        let h = try await EngineHarness()
        let first = await h.gmail.deliver(subject: "Synthetic plan", body: "Synthetic question.")
        let sendAt = h.clock.now.addingTimeInterval(600)
        let condition = SendAtCondition(anchor: GmailMessageID(first.messageID)).headerValue
        let gmailDraft = try await scheduleReply(h, thread: first.threadID, condition: condition, at: sendAt)
        let engine = h.engine()
        await engine.setTestSeams(jitter: .zero)
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        let id = try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(gmailDraft)))

        h.clock.advance(to: sendAt.addingTimeInterval(1))
        try await eventually("queued") { try !sendOps(h, id).isEmpty }
        try await eventually("sent") { try sendOps(h, id).first?.status == .succeeded }
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        let sent = try #require(try await h.sentOnGmail().first)
        #expect(try await !h.rawOnGmail(sent).contains(OHGmailLabels.sendAtConditionHeader))
        #expect(events.cancelledByReply.isEmpty)
        await engine.stop()
    }

    @Test func aConditionThisBuildDoesNotKnowIsNeverSentBlindly() async throws {
        let h = try await EngineHarness()
        let first = await h.gmail.deliver(subject: "Synthetic plan", body: "Synthetic question.")
        let sendAt = h.clock.now.addingTimeInterval(600)
        let gmailDraft = try await scheduleReply(h, thread: first.threadID, condition: "if-opened", at: sendAt)
        let engine = h.engine()
        await engine.setTestSeams(jitter: .zero)
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        let id = try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(gmailDraft)))

        h.clock.advance(to: sendAt.addingTimeInterval(1))
        try await eventually("needs confirmation") { events.needsConfirmation.contains(id) }
        #expect(try h.store.draft(id)?.state == .failed && h.store.draft(id)?.lastError == "unknown send condition")
        #expect(try sendOps(h, id).isEmpty)
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        await engine.stop()
    }

    @Test func theConditionHeaderRoundTrips() {
        #expect(SendAtCondition(anchor: GmailMessageID("m1")).headerValue == "no-reply m1")
        #expect(SendAtCondition(anchor: nil).headerValue == "no-reply")
        #expect(SendAtCondition(headerValue: "no-reply m1") == SendAtCondition(anchor: GmailMessageID("m1")))
        #expect(SendAtCondition(headerValue: " No-Reply ") == SendAtCondition(anchor: nil))
        #expect(SendAtCondition(headerValue: "if-opened") == nil)
        #expect(SendAtCondition(headerValue: "no-reply m1 m2") == nil)
    }
}
