import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct EngineSafeModeTests {
    private let blockedReadOnly = EngineError.blockedBySafeMode("perform: mail changes are off in read-only safe mode")

    @Test func thePolicyTableMatchesTheSpec() {
        func account(_ scopes: [String], _ status: AccountStatus = .active) -> AccountItem {
            AccountItem(id: AccountID(1), email: "me@example.com", position: 0, status: status, sendAs: [],
                        grantedScopes: scopes)
        }
        let modify = account([GmailScope.modify]), readonly = account([GmailScope.readonly])
        let all = Set(ScheduleKind.allCases)
        #expect(EnginePolicy.runsDrainer(safeMode: .normal, account: modify))
        #expect(EnginePolicy.runsDrainer(safeMode: .writeAllowlist, account: modify))
        #expect(!EnginePolicy.runsDrainer(safeMode: .readOnly, account: modify))
        #expect(!EnginePolicy.runsDrainer(safeMode: .normal, account: readonly))
        #expect(!EnginePolicy.runsDrainer(safeMode: .normal, account: account([GmailScope.modify], .removing)))
        #expect(EnginePolicy.schedulerKinds(safeMode: .normal, configured: all, account: modify) == all)
        #expect(EnginePolicy.schedulerKinds(safeMode: .writeAllowlist, configured: all, account: modify) == [.reminder, .snooze])
        #expect(EnginePolicy.schedulerKinds(safeMode: .readOnly, configured: all, account: modify).isEmpty)
        #expect(EnginePolicy.schedulerKinds(safeMode: .normal, configured: all, account: readonly).isEmpty)
        #expect(EnginePolicy.schedulerKinds(safeMode: .normal, configured: [.reminder], account: modify) == [.reminder])

        #expect(throws: EngineError.blockedBySafeMode("x: mail changes are off in read-only safe mode")) {
            try EnginePolicy.checkMailWrite(role: .app, safeMode: .readOnly, what: "x")
        }
        #expect(throws: EngineError.requiresApp("x on a read-only engine")) {
            try EnginePolicy.checkMailWrite(role: .readOnly, safeMode: .normal, what: "x")
        }
        #expect(throws: Never.self) { try EnginePolicy.checkMailWrite(role: .localClient, safeMode: .normal, what: "x") }
        #expect(throws: Never.self) { try EnginePolicy.checkMailWrite(role: .app, safeMode: .writeAllowlist, what: "x") }
        for mode in [SafeMode.readOnly, .writeAllowlist] {
            #expect(throws: EngineError.blockedBySafeMode("send: sending is off in \(mode.rawValue) safe mode")) {
                try EnginePolicy.checkSend(role: .app, safeMode: mode, what: "send")
            }
        }
        for role in [EngineRole.localClient, .readOnly, .cliOneShot, .cliDaemon] {
            #expect(throws: EngineError.sendNotAllowed) { try EnginePolicy.checkSend(role: role, safeMode: .normal, what: "send") }
            #expect(throws: EngineError.requiresApp("sync")) { try EnginePolicy.checkNetwork(role: role, what: "sync") }
        }
        #expect(throws: Never.self) { try EnginePolicy.checkLocalWrite(role: .localClient, what: "snippet") }
    }

    @Test func readOnlyNeverReachesAWritePath() async throws {
        let h = try await EngineHarness(safeMode: .readOnly, scopes: [GmailScope.readonly], stack: true, threads: 12)
        defer { h.cleanup() }
        let wire = try #require(h.wire)
        let engine = h.engine(safeMode: .readOnly)
        await engine.start()
        try await h.waitForSyncs(engine)
        #expect(await engine.drainer(for: h.account) == nil)
        #expect(await engine.scheduler(for: h.account) == nil)
        #expect(Set(try h.inbox()) == Set(h.threads))

        await h.gmail.simulateWebArchive(threadID: h.threads[0])
        await h.gmail.deliver(subject: "Delta")
        h.clock.advance(by: .seconds(60))
        try await h.waitForSyncs(engine, 2)
        #expect(!(try h.inbox()).contains(h.threads[0]))
        await h.gmail.expireAllHistory()
        _ = try await engine.syncNow(h.account, reason: "test")
        _ = try await engine.fetchThread(account: h.account, gmailThreadID: GmailThreadID(h.threads[3]))
        try await engine.ensureBodies(thread: try h.ref(h.threads[3]).rowID)

        let ref = try h.ref(h.threads[1])
        await #expect(throws: blockedReadOnly) { try await engine.perform(.archive([ref]), origin: .app) }
        await #expect(throws: EngineError.self) { try await engine.undo(ActionReceipt(operationIDs: [], undo: .moveToInbox([ref]))) }
        await #expect(throws: EngineError.self) {
            try await engine.perform(.setReminder(ref, dueAt: h.clock.now.addingTimeInterval(3600), condition: .always),
                                     origin: .app)
        }
        await #expect(throws: EngineError.self) {
            try await engine.newDraft(account: h.account, mode: .new, replyTo: nil, origin: .user)
        }
        await #expect(throws: EngineError.self) {
            try await engine.createAgentDraft(account: h.account, mode: .new, replyTo: nil,
                                              content: DraftContent(to: [], cc: [], bcc: [], subject: "s", bodyHTML: "b",
                                                                    attachments: []),
                                              note: nil, origin: .cli)
        }
        await #expect(throws: EngineError.self) { try await engine.createLabel(account: h.account, name: "L", applyTo: [ref]) }
        let receipt = SendReceipt(draftID: DraftID("none"), sendOperationID: OperationID(rawValue: 1), sendAfter: h.clock.now)
        await #expect(throws: EngineError.blockedBySafeMode("send: sending is off in read-only safe mode")) {
            try await engine.send(DraftID("none"), authorization: .userConfirmed, undoWindow: nil)
        }
        await #expect(throws: EngineError.self) { try await engine.sendNow(receipt) }
        await #expect(throws: EngineError.self) { try await engine.scheduleSend(DraftID("none"), at: h.clock.now) }
        #expect(try h.ops().isEmpty)
        #expect(try h.store.drafts(account: h.account, states: [.editing], limit: 10).isEmpty)

        let snippet = try await engine.upsertSnippet(SnippetItem(id: "s1", name: "Thanks", bodyHTML: "Thanks!",
                                                                 variables: [], useCount: 0))
        #expect(snippet.id == "s1")

        #expect(!wire.requests.isEmpty)
        #expect(wire.nonGETRequests.isEmpty, "\(wire.nonGETRequests.map { "\($0.method) \($0.url.path())" })")
        await engine.stop()
    }

    @Test func anAccountWithoutModifyIsReadOnlyInNormalMode() async throws {
        let h = try await EngineHarness(scopes: [GmailScope.readonly], stack: true)
        defer { h.cleanup() }
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        #expect(await engine.drainer(for: h.account) == nil)
        #expect(await engine.scheduler(for: h.account) == nil)
        await #expect(throws: EngineError.blockedBySafeMode("perform: account \(h.account.rawValue) was granted read-only access")) {
            try await engine.perform(.archive([try h.ref(h.threads[0])]), origin: .app)
        }
        #expect(try h.ops().isEmpty)
        #expect(try #require(h.wire).nonGETRequests.isEmpty)
        await engine.stop()
    }

    @Test func writeAllowlistDrainsOnlyTheCampaignsOwnThreadsAndNeverSends() async throws {
        let h = try await EngineHarness(safeMode: .writeAllowlist, stack: true)
        defer { h.cleanup() }
        let wire = try #require(h.wire)
        let api = try h.factory.client(for: "me@example.com")
        let synthetic = try await SyntheticThreads(api: api, runID: "20260921T1413Z-0042")
            .insertThreads(count: 2, date: h.clock.now.addingTimeInterval(-60))
        let engine = h.engine(safeMode: .writeAllowlist)
        let events = EngineEvents(engine)
        await engine.start()
        try await h.waitForSyncs(engine)
        #expect(await engine.drainer(for: h.account) != nil)
        #expect(Set(await engine.scheduler(for: h.account)?.kinds ?? []) == [.reminder, .snooze])
        let writesBefore = wire.nonGETRequests.count

        let own = try await engine.perform(.archive([try h.ref(synthetic[0].threadID)]), origin: .app)
        try await eventually("synthetic archive drained") { try h.store.operation(own.operationIDs[0])?.status == .succeeded }
        #expect(!(await h.serverLabels(ofThread: synthetic[0].threadID)).contains("INBOX"))

        let real = h.threads[0]
        let refused = try await engine.perform(.archive([try h.ref(real)]), origin: .app)
        try await eventually("refused") { try h.store.operation(refused.operationIDs[0])?.status == .failed }
        #expect(try h.store.operation(refused.operationIDs[0])?.lastErrorCode == "safe_mode_blocked")
        #expect(try h.inbox().contains(real))
        #expect((await h.serverLabels(ofThread: real)).contains("INBOX"))
        try await eventually("operationFailed event") { events.failedOperations.contains { $0.id == refused.operationIDs[0] } }
        #expect(wire.nonGETRequests.count == writesBefore + 1)

        let draft = try await engine.newDraft(account: h.account, mode: .new, replyTo: nil, origin: .user)
        let opsBefore = try h.ops()
        await #expect(throws: EngineError.blockedBySafeMode("send: sending is off in write-allowlist safe mode")) {
            try await engine.send(draft.id, authorization: .userConfirmed, undoWindow: nil)
        }
        await #expect(throws: EngineError.self) {
            try await engine.scheduleSend(draft.id, at: h.clock.now.addingTimeInterval(3_600))
        }
        #expect(try h.store.draft(draft.id)?.state == .editing)
        #expect(try h.ops() == opsBefore)
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        #expect(await h.gmail.callCount(.sendMessage) == 0)
        await engine.stop()
    }

    @Test func rolesLocalClientWritesLocallyOnlyAndReadOnlyNeverWrites() async throws {
        let h = try await EngineHarness()
        try await AccountSyncer(account: h.account, store: h.store, api: h.gmail, clock: h.clock).sync(reason: "test")
        await h.gmail.resetAccounting()
        let cli = h.engine(role: .localClient, factory: .some(nil))
        await cli.start()
        #expect(await cli.runtime(for: h.account) == nil)

        let receipt = try await cli.perform(.archive([try h.ref(h.threads[2])]), origin: .cli)
        #expect(try h.store.operation(receipt.operationIDs[0])?.origin == .cli)
        let content = DraftContent(to: [EmailAddress(email: "bob@example.invalid")], cc: [], bcc: [],
                                   subject: "Agent draft", bodyHTML: "<p>Hello</p>", attachments: [])
        let draft = try await cli.createAgentDraft(account: h.account, mode: .new, replyTo: nil, content: content,
                                                   note: "for review", origin: .cli)
        try await cli.updateAgentDraft(draft, content: content, note: "second pass")
        try await cli.setReviewState(draft, .rejected)
        #expect(try h.store.draft(draft)?.reviewState == .rejected)

        await #expect(throws: EngineError.sendNotAllowed) { try await cli.send(draft, authorization: .userConfirmed, undoWindow: nil) }
        await #expect(throws: EngineError.sendNotAllowed) {
            try await cli.sendNow(SendReceipt(draftID: draft, sendOperationID: OperationID(rawValue: 1), sendAfter: h.clock.now))
        }
        await #expect(throws: EngineError.sendNotAllowed) { try await cli.scheduleSend(draft, at: h.clock.now) }
        await #expect(throws: EngineError.requiresApp("syncNow")) { try await cli.syncNow(nil, reason: "cli") }
        await #expect(throws: EngineError.requiresApp("ensureBodies")) { try await cli.ensureBodies(thread: try h.ref(h.threads[0]).rowID) }
        await #expect(throws: EngineError.requiresApp("fetchThread")) {
            try await cli.fetchThread(account: h.account, gmailThreadID: GmailThreadID(h.threads[0]))
        }
        await #expect(throws: EngineError.requiresApp("attachmentFile")) { try await cli.attachmentFile(1) }
        await #expect(throws: EngineError.requiresApp("remoteSearch")) { try await cli.remoteSearch("x", account: h.account, maxResults: 5) }
        await #expect(throws: EngineError.requiresApp("sign-in")) {
            try await cli.addAccount(using: FakeGoogleSignIn(gmail: h.gmail, clock: h.clock).flow(.normal), loginHint: nil)
        }
        #expect(try h.store.lease(account: h.account) == nil)
        #expect(await h.gmail.callLog.isEmpty)

        let reader = h.engine(role: .readOnly, factory: .some(nil))
        await #expect(throws: EngineError.requiresApp("perform on a read-only engine")) {
            try await reader.perform(.archive([try h.ref(h.threads[0])]), origin: .cli)
        }
        await #expect(throws: EngineError.requiresApp("upsertSnippet on a read-only engine")) {
            try await reader.upsertSnippet(SnippetItem(id: "s", name: "n", bodyHTML: "b", variables: [], useCount: 0))
        }
        let waited = await cli.waitForOperations(receipt.operationIDs, timeout: .milliseconds(200))
        #expect(waited[receipt.operationIDs[0]] == .pending)
    }
}
