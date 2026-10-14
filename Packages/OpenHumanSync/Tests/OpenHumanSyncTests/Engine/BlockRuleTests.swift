import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

func saveBlockRule(_ store: MailStore, _ account: AccountID, _ kind: BlockRule.Kind, _ value: String,
           _ disposition: BlockDisposition? = nil, since createdAt: Date = Date(timeIntervalSince1970: 0)) throws {
    let rule = try #require(BlockRule(kind: kind, value: value, disposition: disposition, createdAt: createdAt))
    var rules = try store.setting(BlockIngest.rulesKey(), scope: .account(account))
    rules.insert(rule, at: 0)
    try store.setSetting(BlockIngest.rulesKey(), rules, scope: .account(account))
}

func blockRuleOps(_ ops: [OperationItem]) -> [OperationItem] {
    ops.filter { op in
        guard op.origin == .scheduler, case let .modifyLabels(_, add, remove, names) = op.payload else { return false }
        return names.isEmpty && BlockIngest.isBlockOp(add: add, remove: remove)
    }
}

@Suite struct BlockRuleEngineTests {
    @Test func newMailFromABlockedAddressIsArchivedAndMarkedReadOnGmail() async throws {
        let h = try await EngineHarness()
        try saveBlockRule(h.store, h.account, .sender, "news@acme.example")
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)

        let blocked = await h.gmail.deliver(from: "Acme News <News+Weekly@acme.example>")
        let other = await h.gmail.deliver(from: "Friend <friend@other.example>")
        _ = try await engine.syncNow(h.account, reason: "test")
        #expect(!(try h.inbox().contains(blocked.threadID)), "kept out of the inbox at once (the queued change)")
        #expect(try h.inbox().contains(other.threadID))
        #expect(blockRuleOps(try h.ops()).count == 1)
        _ = await engine.drainer(for: h.account)?.drainOnce()
        try await eventually("archived and read on Gmail") {
            guard let labels = await h.gmail.labelIDs(ofMessage: blocked.messageID) else { return false }
            return !labels.contains("INBOX") && !labels.contains("UNREAD") && !labels.contains("TRASH")
        }
        #expect((await h.gmail.labelIDs(ofMessage: other.messageID) ?? []).contains("INBOX"))
        _ = try await engine.syncNow(h.account, reason: "test")
        #expect(!(try h.inbox().contains(blocked.threadID)), "Gmail's echo agrees")
        #expect(Set(try h.inbox()) == Set(h.threads + [other.threadID]))
        await engine.stop()
    }

    @Test func aDomainRuleThatSaysTrashMovesSubdomainMailToTrashButNotALookAlike() async throws {
        let h = try await EngineHarness()
        try saveBlockRule(h.store, h.account, .domain, "acme.example", .trash)
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)

        let sub = await h.gmail.deliver(from: "Alerts <alerts@mail.acme.example>")
        let lookAlike = await h.gmail.deliver(from: "Promo <promo@acme.example.net>")
        _ = try await engine.syncNow(h.account, reason: "test")
        _ = await engine.drainer(for: h.account)?.drainOnce()
        try await eventually("in Trash on Gmail") {
            let labels = await h.gmail.labelIDs(ofMessage: sub.messageID) ?? []
            return labels.contains("TRASH") && !labels.contains("INBOX")
        }
        #expect((await h.gmail.labelIDs(ofMessage: lookAlike.messageID) ?? []).contains("INBOX"))
        #expect(try h.inbox().contains(lookAlike.threadID))
        #expect(!(try h.inbox().contains(sub.threadID)))
        await engine.stop()
    }

    @Test func mailTheAuthorSentIsNeverTouched() async throws {
        let h = try await EngineHarness()
        try saveBlockRule(h.store, h.account, .domain, "acme.example")
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)

        let sent = await h.gmail.deliver(from: "Me <me@example.com>", to: "bob@acme.example", labels: ["SENT"])
        let both = await h.gmail.deliver(from: "Bob <bob@acme.example>", labels: ["INBOX", "SENT"])
        _ = try await engine.syncNow(h.account, reason: "test")
        #expect(blockRuleOps(try h.ops()).isEmpty)
        #expect((await h.gmail.labelIDs(ofMessage: sent.messageID) ?? []) == ["SENT"])
        #expect(try h.inbox().contains(both.threadID))
        await engine.stop()
    }

    @Test func aReadOnlyEngineQueuesNothingAndShowsGmailsState() async throws {
        let h = try await EngineHarness()
        try saveBlockRule(h.store, h.account, .sender, "news@acme.example")
        let engine = h.engine(safeMode: .readOnly)
        await engine.start()
        try await h.waitForSyncs(engine)
        let blocked = await h.gmail.deliver(from: "news@acme.example")
        _ = try await engine.syncNow(h.account, reason: "test")
        #expect(try h.ops().isEmpty, "read-only never queues a change")
        #expect(try h.inbox().contains(blocked.threadID))
        #expect((await h.gmail.labelIDs(ofMessage: blocked.messageID) ?? []).contains("INBOX"))
        await engine.stop()
    }
}

@Suite struct BlockRuleQueueTests {
    func blockingSyncer(_ h: WriteHarness) throws -> AccountSyncer {
        AccountSyncer(account: h.account, store: h.store, api: try h.client, clock: h.clock, blocking: h.store)
    }

    func plainSync(_ h: WriteHarness) async throws {
        try await AccountSyncer(account: h.account, store: h.store, api: try h.client, clock: h.clock).sync(reason: "test")
    }

    func ruleOps(_ h: WriteHarness) throws -> [OperationItem] { blockRuleOps(try h.ops()) }

    @Test func aRuleOpThatWaitedOutAnOutageStillRuns() async throws {
        let h = try await WriteHarness(clock: sendClock())
        try saveBlockRule(h.store, h.account, .sender, "news@acme.example")
        let syncer = try blockingSyncer(h)
        try await syncer.sync(reason: "test")
        let blocked = await h.gmail.deliver(from: "news@acme.example")
        try await syncer.sync(reason: "test")
        #expect(try ruleOps(h).count == 1)
        await h.gmail.failNext(.batchModify, with: .transport(.notConnected))
        let drainer = h.drainer(api: h.gmail)
        #expect(await drainer.drainOnce().released == 1)
        h.instant.advance(by: .seconds(180))
        let report = await drainer.drainOnce()
        #expect(report.cancelled == 0 && report.succeeded == 1)
        #expect(!((await h.gmail.labelIDs(ofMessage: blocked.messageID)) ?? ["INBOX"]).contains("INBOX"))
        #expect(!(try h.inbox().contains(blocked.threadID)), "never back in the inbox")
    }

    @Test func aMessageTheArrivalRuleMissedIsRefiledByTheNextPass() async throws {
        let h = try await WriteHarness(clock: sendClock())
        try saveBlockRule(h.store, h.account, .domain, "acme.example")
        let syncer = try blockingSyncer(h)
        try await syncer.sync(reason: "test")
        let blocked = await h.gmail.deliver(from: "alerts@mail.acme.example")
        try await plainSync(h)
        #expect(try h.inbox().contains(blocked.threadID))
        #expect(try ruleOps(h).isEmpty)

        try await syncer.sync(reason: "test")
        #expect(try ruleOps(h).count == 1)
        #expect(!(try h.inbox().contains(blocked.threadID)))
        _ = await h.drainer(api: h.gmail).drainOnce()
        let labels = try #require(await h.gmail.labelIDs(ofMessage: blocked.messageID))
        #expect(!labels.contains("INBOX") && !labels.contains("UNREAD"))
        try await syncer.sync(reason: "test")
        #expect(try ruleOps(h).count == 1, "idempotent: nothing left to change")
    }

    @Test func mailFromBeforeTheBlockStaysWhereItIs() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let older = await h.gmail.deliver(from: "news@acme.example")
        try await plainSync(h)
        let olderDate = try #require(try h.store.threadDetail(try h.ref(older.threadID).rowID)?.messages.last?.date)
        try saveBlockRule(h.store, h.account, .sender, "news@acme.example", since: olderDate.addingTimeInterval(1))
        let syncer = try blockingSyncer(h)
        try await syncer.sync(reason: "test")
        #expect(try ruleOps(h).isEmpty)
        #expect(try h.inbox().contains(older.threadID))

        let newer = await h.gmail.deliver(from: "news@acme.example")
        try await plainSync(h)
        try await syncer.sync(reason: "test")
        #expect(try ruleOps(h).count == 1, "the newer one only")
        #expect(!(try h.inbox().contains(newer.threadID)))
        #expect(try h.inbox().contains(older.threadID))
    }

    @Test func aMessageTheAuthorMovedBackToTheInboxIsNotRefiledAgain() async throws {
        let h = try await WriteHarness(clock: sendClock())
        try saveBlockRule(h.store, h.account, .sender, "news@acme.example")
        let syncer = try blockingSyncer(h)
        try await syncer.sync(reason: "test")
        let blocked = await h.gmail.deliver(from: "news@acme.example")
        try await syncer.sync(reason: "test")
        _ = await h.drainer(api: h.gmail).drainOnce()
        #expect(!((await h.gmail.labelIDs(ofMessage: blocked.messageID)) ?? ["INBOX"]).contains("INBOX"))

        await h.gmail.modifyLabels(messageID: blocked.messageID, add: ["INBOX"])
        try h.store.garbageCollectOperations(now: Date().addingTimeInterval(2 * 3_600))
        #expect(try ruleOps(h).isEmpty)
        try await syncer.sync(reason: "test")
        try await syncer.sync(reason: "test")
        #expect(try ruleOps(h).isEmpty, "the user's choice stands")
        #expect(try h.inbox().contains(blocked.threadID))
    }

    @Test func aRefusedRuleOpIsNotQueuedAgainByEveryPass() async throws {
        let h = try await WriteHarness(clock: sendClock())
        try saveBlockRule(h.store, h.account, .sender, "news@acme.example")
        let syncer = try blockingSyncer(h)
        try await syncer.sync(reason: "test")
        let blocked = await h.gmail.deliver(from: "news@acme.example")
        try await syncer.sync(reason: "test")
        await h.gmail.failNext(.batchModify, with: .badRequest(reason: nil, message: "synthetic"))
        #expect(await h.drainer(api: h.gmail).drainOnce().failed == 1)
        try await syncer.sync(reason: "test")
        #expect(try ruleOps(h).count == 1, "the failure was shown once; the next pass does not repeat it")
        #expect(try h.inbox().contains(blocked.threadID))
    }
}
