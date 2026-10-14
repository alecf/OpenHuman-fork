import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct SendLaterTwoInstallTests {
    struct Installs {
        let a: EngineHarness, b: EngineHarness
        let engineA: MailEngine, engineB: MailEngine
        let probeB: ProbeGmail
        let draftA: DraftID, draftB: DraftID
        let sendAt: Date

        func sendOps(_ h: EngineHarness, _ draft: DraftID) throws -> [OperationItem] {
            try h.ops().filter { if case let .sendDraft(id) = $0.payload { return id == draft } else { return false } }
        }

        func settled(_ engine: MailEngine, _ h: EngineHarness, _ draft: DraftID, _ what: String) async throws {
            let scheduler = try #require(await engine.scheduler(for: h.account))
            try await eventually(what) {
                let idle = await scheduler.nextFire != nil
                return try idle && h.store.draft(draft)?.state != .scheduled
            }
        }
    }

    private func installs(jitterA: Duration, jitterB: Duration) async throws -> Installs {
        let a = try await EngineHarness()
        let b = try await EngineHarness(threads: 0, clock: a.clock, gmail: a.gmail)
        let probeB = ProbeGmail(a.gmail)
        let engineA = a.engine(), engineB = b.engine(factory: FixedGmailFactory(api: probeB))
        await engineA.setTestSeams(jitter: jitterA)
        await engineB.setTestSeams(jitter: jitterB)
        await engineA.start()
        await engineB.start()
        try await a.waitForSyncs(engineA)
        try await b.waitForSyncs(engineB)

        let content = DraftContent(to: [EmailAddress(email: "bob@example.invalid")], cc: [], bcc: [],
                                   subject: "Synthetic send later", bodyHTML: "<p>Synthetic body.</p>", attachments: [])
        let created = try await engineA.newDraft(account: a.account, mode: .new, replyTo: nil, origin: .user, initial: content)
        let sendAt = a.clock.now.addingTimeInterval(600)
        try await engineA.scheduleSend(created.id, at: sendAt)
        try await eventually("A uploaded it with its schedule") {
            let draft = try a.store.draft(created.id), idle = try a.ops([.pending, .inFlight]).isEmpty
            return draft?.state == .scheduled && draft?.isDirty == false && draft?.gmailDraftID != nil && idle
        }
        let gmailDraft = try #require(try a.store.draft(created.id)?.gmailDraftID)
        _ = try await engineA.syncNow(a.account, reason: "test")
        _ = try await engineB.syncNow(b.account, reason: "test")
        try await eventually("B holds it as scheduled") {
            try b.store.draft(account: b.account, gmailDraftID: gmailDraft)?.state == .scheduled
        }
        let draftB = try #require(try b.store.draft(account: b.account, gmailDraftID: gmailDraft))
        #expect(draftB.sendAt == sendAt && draftB.origin == .user)
        return Installs(a: a, b: b, engineA: engineA, engineB: engineB, probeB: probeB, draftA: created.id,
                        draftB: draftB.id, sendAt: sendAt)
    }

    private func expectSentExactlyOnce(_ p: Installs, _ what: String) async throws {
        try await p.a.expectOneCleanSentMessage(what)
        #expect(await p.a.gmail.callCount(.sendMessage) == 0, "\(what)")
        _ = try await p.engineA.syncNow(p.a.account, reason: "test")
        _ = try await p.engineB.syncNow(p.b.account, reason: "test")
        let stateA = try p.a.store.draft(p.draftA)?.state, stateB = try p.b.store.draft(p.draftB)?.state
        #expect(stateA == .sent || stateA == .discarded, "\(what): A \(String(describing: stateA))")
        #expect(stateB == .sent || stateB == .discarded, "\(what): B \(String(describing: stateB))")
        #expect((stateA == .sent) != (stateB == .sent), "\(what)")
        await p.engineA.stop()
        await p.engineB.stop()
    }

    @Test func sequentiallyTheLaterInstallFindsItSentAndSendsNothing() async throws {
        let p = try await installs(jitterA: .seconds(2), jitterB: .seconds(9))
        p.a.clock.advance(to: p.sendAt.addingTimeInterval(2))
        try await eventually("A sent it") { try p.sendOps(p.a, p.draftA).first?.status == .succeeded }
        p.a.clock.advance(to: p.sendAt.addingTimeInterval(9))
        try await p.settled(p.engineB, p.b, p.draftB, "B saw it go (its poll or its preflight)")
        #expect(try p.sendOps(p.b, p.draftB).isEmpty)
        #expect(await p.a.gmail.callCount(.sendDraft) == 1)
        try await expectSentExactlyOnce(p, "sequential")
    }

    @Test func theLaterInstallHeldBeforeItsPreflightReadFindsTheDraftConsumed() async throws {
        let p = try await installs(jitterA: .seconds(9), jitterB: .seconds(2))
        let gate = p.probeB.pauseNext(.getDraft)
        p.a.clock.advance(to: p.sendAt.addingTimeInterval(2))
        try await eventually("B held before drafts.get") { gate.reached }
        p.a.clock.advance(to: p.sendAt.addingTimeInterval(9))
        try await eventually("A sent it") { try p.sendOps(p.a, p.draftA).first?.status == .succeeded }
        gate.open()
        try await p.settled(p.engineB, p.b, p.draftB, "B's drafts.get answered 404: consumed elsewhere")
        #expect(try p.sendOps(p.b, p.draftB).isEmpty)
        #expect(await p.a.gmail.callCount(.sendDraft) == 1)
        try await expectSentExactlyOnce(p, "before getDraft")
    }

    @Test func theLaterInstallHeldBeforeItsStripFindsTheDraftGoneAndNeverSends() async throws {
        let p = try await installs(jitterA: .seconds(9), jitterB: .seconds(2))
        let gate = p.probeB.pauseNext(.updateDraft)
        p.a.clock.advance(to: p.sendAt.addingTimeInterval(2))
        try await eventually("B held before its 3a drafts.update") { gate.reached }
        p.a.clock.advance(to: p.sendAt.addingTimeInterval(9))
        try await eventually("A sent it") { try p.sendOps(p.a, p.draftA).first?.status == .succeeded }
        gate.open()
        try await eventually("B's send ended") { try p.sendOps(p.b, p.draftB).first?.status == .cancelled }
        let op = try #require(try p.sendOps(p.b, p.draftB).first)
        #expect(op.lastErrorCode == "target_gone")
        #expect(await p.a.gmail.callCount(.sendDraft) == 1)
        try await expectSentExactlyOnce(p, "before 3a")
    }

    @Test func anInstallThatSeesTheOtherOnesStripSendsNothingWhileTheOtherSends() async throws {
        let p = try await installs(jitterA: .seconds(9), jitterB: .seconds(2))
        let gate = p.probeB.pauseNext(.sendDraft)
        p.a.clock.advance(to: p.sendAt.addingTimeInterval(2))
        try await eventually("B held before drafts.send") { gate.reached }
        p.a.clock.advance(to: p.sendAt.addingTimeInterval(9))
        try await p.settled(p.engineA, p.a, p.draftA, "A saw the schedule header gone")
        #expect(try p.sendOps(p.a, p.draftA).isEmpty)
        gate.open()
        try await eventually("B sent it") { try p.sendOps(p.b, p.draftB).first?.status == .succeeded }
        #expect(await p.a.gmail.callCount(.sendDraft) == 1)
        try await expectSentExactlyOnce(p, "before sendDraft")
    }
}
