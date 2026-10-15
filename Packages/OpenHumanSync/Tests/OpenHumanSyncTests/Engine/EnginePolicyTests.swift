import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct EnginePolicyTests {
    static let gmailWrites: Set<GmailMethod> = [
        .createLabel, .trashThread, .untrashThread, .batchModify, .modifyMessage, .trashMessage, .untrashMessage,
        .sendMessage, .insertMessage, .createDraft, .updateDraft, .deleteDraft, .sendDraft,
    ]

    @Test func theRoleAndGrantTablesMatchTheSpec() {
        func account(_ scopes: [String], _ status: AccountStatus = .active) -> AccountItem {
            AccountItem(id: AccountID(1), email: "me@example.com", position: 0, status: status, sendAs: [],
                        grantedScopes: scopes)
        }
        let modify = account([GmailScope.modify]), readonly = account([GmailScope.readonly])
        let all = Set(ScheduleKind.allCases)
        #expect(EnginePolicy.runsDrainer(account: modify))
        #expect(EnginePolicy.runsDrainer(account: account([GmailScope.modify], .needsReauth)))
        #expect(!EnginePolicy.runsDrainer(account: readonly))
        #expect(!EnginePolicy.runsDrainer(account: account([])))
        #expect(!EnginePolicy.runsDrainer(account: account([GmailScope.modify], .removing)))
        #expect(EnginePolicy.schedulerKinds(configured: all, account: modify) == all)
        #expect(EnginePolicy.schedulerKinds(configured: [.reminder], account: modify) == [.reminder])
        #expect(EnginePolicy.schedulerKinds(configured: all, account: readonly).isEmpty)
        #expect(EnginePolicy.schedulerKinds(configured: all, account: account([GmailScope.modify], .removing)).isEmpty)

        #expect(throws: EngineError.requiresApp("x on a read-only engine")) {
            try EnginePolicy.checkMailWrite(role: .readOnly, what: "x")
        }
        for role in [EngineRole.app, .localClient, .cliOneShot, .cliDaemon] {
            #expect(throws: Never.self) { try EnginePolicy.checkMailWrite(role: role, what: "x") }
        }
        #expect(throws: Never.self) { try EnginePolicy.checkSend(role: .app, what: "send") }
        for role in [EngineRole.localClient, .readOnly, .cliOneShot, .cliDaemon] {
            #expect(throws: EngineError.sendNotAllowed) { try EnginePolicy.checkSend(role: role, what: "send") }
            #expect(throws: EngineError.requiresApp("sync")) { try EnginePolicy.checkNetwork(role: role, what: "sync") }
        }
        #expect(throws: Never.self) { try EnginePolicy.checkLocalWrite(role: .localClient, what: "snippet") }
        #expect(throws: EngineError.requiresApp("snippet on a read-only engine")) {
            try EnginePolicy.checkLocalWrite(role: .readOnly, what: "snippet")
        }
    }

    @Test func anAccountWithoutModifyRunsNoDrainerAndItsWritesThrowWriteAccessMissing() async throws {
        let h = try await EngineHarness(scopes: [GmailScope.readonly])
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        #expect(await engine.runtime(for: h.account) != nil)
        #expect(await engine.drainer(for: h.account) == nil)
        #expect(await engine.scheduler(for: h.account) == nil)

        let account = h.account
        func missing(_ what: String) -> EngineError {
            .writeAccessMissing("\(what): account \(account.rawValue) has not granted gmail.modify")
        }
        let ref = try h.ref(h.threads[0])
        await #expect(throws: missing("perform")) { try await engine.perform(.archive([ref]), origin: .app) }
        await #expect(throws: missing("perform")) {
            try await engine.perform(.setReminder(ref, dueAt: h.clock.now.addingTimeInterval(3600), condition: .always),
                                     origin: .app)
        }
        await #expect(throws: missing("perform")) { try await engine.createLabel(account: account, name: "L", applyTo: [ref]) }
        await #expect(throws: missing("undo")) {
            try await engine.undo(ActionReceipt(operationIDs: [], undo: .moveToInbox([ref])))
        }
        await #expect(throws: missing("newDraft")) {
            try await engine.newDraft(account: account, mode: .new, replyTo: nil, origin: .user)
        }
        let draft = try h.store.createDraft(account: account, mode: .new, replyTo: nil,
                                            content: DraftContent(to: [EmailAddress(email: "bob@example.com")], cc: [],
                                                                  bcc: [], subject: "Synthetic",
                                                                  bodyHTML: "<p>Synthetic</p>", attachments: []),
                                            origin: .user, reviewState: .none, agentNote: nil, extraHeaders: [:])
        await #expect(throws: missing("send")) {
            try await engine.send(draft, authorization: .userConfirmed, undoWindow: nil)
        }
        await #expect(throws: missing("scheduleSend")) {
            try await engine.scheduleSend(draft, at: h.clock.now.addingTimeInterval(3600))
        }

        #expect(try h.ops().isEmpty)
        #expect(try h.store.draft(draft)?.state == .editing)
        let calls = await h.gmail.callLog
        #expect(!calls.contains(where: Self.gmailWrites.contains), "\(calls)")
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
            try await cli.addAccount(using: FakeGoogleSignIn(gmail: h.gmail, clock: h.clock).flow(), loginHint: nil)
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
