import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct MuteRuleTests {
    func muteOnServer(_ h: EngineHarness, _ thread: String, keepInInbox: Bool = false) async -> String {
        var label = await h.gmail.labelID(named: OHGmailLabels.muted)
        if label == nil { label = await h.gmail.addUserLabel(OHGmailLabels.muted) }
        let muted = label!
        for message in await h.gmail.messageIDs(inThread: thread) {
            await h.gmail.modifyLabels(messageID: message, add: [muted], remove: keepInInbox ? [] : ["INBOX"])
        }
        return muted
    }

    func ruleOps(_ h: EngineHarness) throws -> [OperationItem] {
        try h.ops().filter { $0.origin == .scheduler && $0.kind == .modifyLabels }
    }

    @Test func mailArrivingInAMutedConversationSkipsTheInbox() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let thread = h.threads[1]
        let ref = try h.ref(thread)
        _ = try await engine.createLabel(account: h.account, name: OHGmailLabels.muted, applyTo: [ref])
        _ = try await engine.perform(.archive([ref]), origin: .app)
        try await eventually("muted on Gmail") {
            guard let muted = await h.gmail.labelID(named: OHGmailLabels.muted) else { return false }
            let labels = await h.serverLabels(ofThread: thread)
            return labels.contains(muted) && !labels.contains("INBOX")
        }
        let muted = try #require(await h.gmail.labelID(named: OHGmailLabels.muted))

        let reply = await h.gmail.deliver(threadID: thread)
        _ = try await engine.syncNow(h.account, reason: "test")
        #expect(!(try h.inbox().contains(thread)), "kept out of the inbox at once (the queued change)")
        #expect(try ruleOps(h).count == 1)
        _ = await engine.drainer(for: h.account)?.drainOnce()
        try await eventually("the new message is muted on Gmail") {
            let labels = await h.gmail.labelIDs(ofMessage: reply.messageID) ?? []
            return labels.contains(muted) && !labels.contains("INBOX")
        }
        _ = try await engine.syncNow(h.account, reason: "test")
        #expect(!(try h.inbox().contains(thread)))
        #expect(Set(try h.inbox()) == Set(h.threads).subtracting([thread]))
        await engine.stop()
    }

    @Test func aMutedConversationTheUserMovedBackKeepsItsOlderMessagesInTheInbox() async throws {
        let h = try await EngineHarness()
        let thread = h.threads[0]
        let muted = await muteOnServer(h, thread, keepInInbox: true)
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let older = await h.gmail.messageIDs(inThread: thread)

        let reply = await h.gmail.deliver(threadID: thread)
        _ = try await engine.syncNow(h.account, reason: "test")
        _ = await engine.drainer(for: h.account)?.drainOnce()
        try await eventually("only the new message changed") {
            let labels = await h.gmail.labelIDs(ofMessage: reply.messageID) ?? []
            return labels.contains(muted) && !labels.contains("INBOX")
        }
        for id in older { #expect((await h.gmail.labelIDs(ofMessage: id) ?? []).contains("INBOX")) }
        #expect(try h.inbox().contains(thread), "the user's choice stands")
        await engine.stop()
    }

    @Test func anUnmutedConversationIsUntouched() async throws {
        let h = try await EngineHarness()
        _ = await muteOnServer(h, h.threads[2])
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let thread = h.threads[0]
        let reply = await h.gmail.deliver(threadID: thread)
        _ = try await engine.syncNow(h.account, reason: "test")
        #expect(try ruleOps(h).isEmpty)
        #expect(try h.inbox().contains(thread))
        #expect((await h.gmail.labelIDs(ofMessage: reply.messageID) ?? []).contains("INBOX"))
        await engine.stop()
    }

    @Test func anAccountWithoutModifyQueuesNothingAndShowsGmailsState() async throws {
        let h = try await EngineHarness(scopes: [GmailScope.readonly])
        let thread = h.threads[1]
        _ = await muteOnServer(h, thread)
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        #expect(!(try h.inbox().contains(thread)))
        #expect(await engine.drainer(for: h.account) == nil)

        let reply = await h.gmail.deliver(threadID: thread)
        _ = try await engine.syncNow(h.account, reason: "test")
        #expect(try h.ops().isEmpty, "an account without write access never queues a change")
        #expect(try h.inbox().contains(thread), "the conversation shows where Gmail has it")
        #expect((await h.gmail.labelIDs(ofMessage: reply.messageID) ?? []).contains("INBOX"))
        await engine.stop()
    }
}

@Suite struct MuteRuleQueueTests {
    func mutedHarness() async throws -> (h: WriteHarness, syncer: AccountSyncer, thread: String, muted: String) {
        let h = try await WriteHarness(clock: sendClock())
        let thread = h.threads[1]
        let muted = await h.gmail.addUserLabel(OHGmailLabels.muted)
        for message in await h.gmail.messageIDs(inThread: thread) {
            await h.gmail.modifyLabels(messageID: message, add: [muted], remove: ["INBOX"])
        }
        let syncer = AccountSyncer(account: h.account, store: h.store, api: try h.client, clock: h.clock, muting: h.store)
        try await syncer.sync(reason: "test")
        #expect(!(try h.inbox().contains(thread)))
        return (h, syncer, thread, muted)
    }

    func ruleOps(_ h: WriteHarness) throws -> [OperationItem] {
        try h.ops().filter { $0.origin == .scheduler && $0.kind == .modifyLabels }
    }

    @Test func aRuleOpThatWaitedOutAnOutageStillRuns() async throws {
        let (h, syncer, thread, muted) = try await mutedHarness()
        let reply = await h.gmail.deliver(threadID: thread)
        try await syncer.sync(reason: "test")
        #expect(try ruleOps(h).count == 1)
        await h.gmail.failNext(.batchModify, with: .transport(.notConnected))
        let drainer = h.drainer(api: h.gmail)
        #expect(await drainer.drainOnce().released == 1)
        h.instant.advance(by: .seconds(180))
        let report = await drainer.drainOnce()
        #expect(report.cancelled == 0 && report.succeeded == 1)
        let labels = await h.gmail.labelIDs(ofMessage: reply.messageID) ?? []
        #expect(labels.contains(muted) && !labels.contains("INBOX"))
        #expect(!(try h.inbox().contains(thread)), "never back in the inbox")
    }

    @Test func aKnownMessageTheRuleMissedIsRefiledByTheNextPass() async throws {
        let (h, syncer, thread, muted) = try await mutedHarness()
        let reply = await h.gmail.deliver(threadID: thread)
        let plain = AccountSyncer(account: h.account, store: h.store, api: try h.client, clock: h.clock)
        try await plain.sync(reason: "test")
        #expect(try h.inbox().contains(thread))
        #expect(try ruleOps(h).isEmpty)

        try await syncer.sync(reason: "test")
        #expect(try ruleOps(h).count == 1)
        #expect(!(try h.inbox().contains(thread)))
        _ = await h.drainer(api: h.gmail).drainOnce()
        let labels = await h.gmail.labelIDs(ofMessage: reply.messageID) ?? []
        #expect(labels.contains(muted) && !labels.contains("INBOX"))
        try await syncer.sync(reason: "test")
        #expect(try ruleOps(h).count == 1, "idempotent: nothing left to change")
    }

    @Test func aRefusedRuleOpIsNotQueuedAgainByEveryPass() async throws {
        let (h, syncer, thread, _) = try await mutedHarness()
        _ = await h.gmail.deliver(threadID: thread)
        try await syncer.sync(reason: "test")
        await h.gmail.failNext(.batchModify, with: .badRequest(reason: nil, message: "synthetic"))
        #expect(await h.drainer(api: h.gmail).drainOnce().failed == 1)
        try await syncer.sync(reason: "test")
        #expect(try ruleOps(h).count == 1, "the failure was shown once; the next pass does not repeat it")
        #expect(try h.inbox().contains(thread))
    }
}
