import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct EngineEndToEndTests {
    @Test func addAccountSyncArchiveOfflineReconnectSendWithUndoAndQuitFlush() async throws {
        let clock = TestClock(now: currentMinute())
        let gmail = FakeGmail(accountEmail: "me@example.com", clock: clock, startDate: clock.now.addingTimeInterval(-86_400))
        let threads = await gmail.seedInbox(count: 5)
        let google = FakeGoogleSignIn(gmail: gmail, clock: clock)
        let tokens = InMemoryTokenStore()
        let wire = FakeGmailTransport(gmail)
        let factory = DefaultGmailClientFactory(tokenStore: tokens, oauthClient: FakeGoogleSignIn.client,
                                                apiTransport: wire, tokenTransport: google.transport,
                                                config: engineGmailConfig, clock: clock)
        let store = try MailStore.openInMemoryForTesting()
        let engine = MailEngine(store: store, gmailFactory: factory, tokenStore: tokens, oauthClient: FakeGoogleSignIn.client,
                                configuration: EngineConfiguration(role: .app, appVersion: "0.0.0-test",
                                                                   gmail: engineGmailConfig, clock: clock),
                                systemEvents: nil)
        await engine.start()

        let account = try await engine.addAccount(using: google.flow(), loginHint: nil)
        #expect(account.email == "me@example.com")
        #expect(account.grantedScopes == [GmailScope.modify])
        #expect(try tokens.load(account: "me@example.com")?.refreshToken == "synthetic-refresh")
        try await eventually("initial sync") {
            Set(try store.threadPage(view: .system(account.id, .inbox), after: nil, limit: 50).items
                .map(\.ref.gmailThreadID.rawValue)) == Set(threads)
        }
        #expect(try store.lease(account: account.id)?.ownerID == store.writerID)

        let ref = try #require(try store.thread(account: account.id, gmailThreadID: GmailThreadID(threads[0])))
        await gmail.failNext(.batchModify, with: .transport(.notConnected))
        let archive = try await engine.perform(.archive([ref]), origin: .app)
        try await eventually("released offline") {
            try store.operation(archive.operationIDs[0])?.nextRetryAt == clock.now.addingTimeInterval(30)
        }
        clock.advance(by: .seconds(30))
        try await eventually("applied after reconnect") { try store.operation(archive.operationIDs[0])?.status == .succeeded }
        var serverLabels = Set<String>()
        for id in await gmail.messageIDs(inThread: threads[0]) { serverLabels.formUnion(await gmail.labelIDs(ofMessage: id) ?? []) }
        #expect(!serverLabels.contains("INBOX"))

        // Long undo window: the Store stamps it on the wall clock, which the virtual clock may already have passed by up to 30 s
        let remote = try await gmail.createDraft(rawRFC822: rawDraft(subject: "Synthetic send"), threadID: nil)
        let draft = try #require(try await engine.fetchDraft(account: account.id, gmailDraftID: GmailDraftID(remote.id)))
        let undone = try await engine.send(draft, authorization: .userConfirmed, undoWindow: .seconds(600))
        #expect(try await engine.cancelSend(undone))
        #expect(try store.draft(draft)?.state == .editing)
        #expect(await gmail.callCount(.sendDraft) == 0)

        let receipt = try await engine.send(draft, authorization: .userConfirmed, undoWindow: .seconds(600))
        clock.advance(by: .seconds(120))
        #expect(try store.operation(receipt.sendOperationID)?.status == .pending)
        await engine.flushPendingSends(deadline: .seconds(20))
        #expect(try store.operation(receipt.sendOperationID)?.status != .pending)
        try await eventually("sent") { try store.operation(receipt.sendOperationID)?.status == .succeeded }
        #expect(await gmail.callCount(.sendMessage) == 0)
        #expect(await gmail.callCount(.sendDraft) == 1)
        #expect(try store.draft(draft)?.state == .sent)
        let sent = try await sentOnGmail(gmail)
        #expect(sent.count == 1)
        for id in sent { #expect(lines(try await rawOnGmail(gmail, id), startingWith: "x-openhuman-").isEmpty) }
        await engine.stop()
        #expect(try store.lease(account: account.id) == nil)
    }

    @Test func aLocalClientsAgentDraftReachesGmailDraftsMarkedAndOnlyTheAppSendsIt() async throws {
        let h = try await EngineHarness(onDisk: true)
        defer { h.cleanup() }
        let directory = try #require(h.directory)
        let cliStore = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .cli,
                                                       appVersion: "0.0.0-test",
                                                       changeNotificationName: "dev.openhuman.test.\(UUID().uuidString)"))
        let cli = h.engine(role: .localClient, factory: .some(nil), store: cliStore)
        let probe = ProbeGmail(h.gmail)
        let drainer = OperationDrainer(account: h.account, store: h.store, api: probe, clock: h.clock, ownerID: "test-app")
        var content = DraftContent(to: [EmailAddress(email: "bob@example.invalid")], cc: [], bcc: [], subject: "From an agent",
                                   bodyHTML: "<p>Synthetic first pass.</p>", attachments: [])
        let draft = try await cli.createAgentDraft(account: h.account, mode: .new, replyTo: nil, content: content,
                                                   note: "please review", origin: .cli)
        let upload = try #require(try h.store.operations(account: h.account, statuses: [.pending], limit: 10).first)
        #expect(upload.kind == .upsertDraft && upload.origin == .cli)
        #expect(try h.store.lease(account: h.account) == nil)

        await drainer.drainOnce()
        #expect(try h.store.operation(upload.id)?.status == .succeeded)
        let first = try #require(try h.store.draft(draft)?.gmailMessageID).rawValue
        #expect(await h.labelNames(ofMessage: first).contains(OHGmailLabels.agent))
        #expect(lines(try await h.rawOnGmail(first), startingWith: "x-openhuman-origin:") == ["X-OpenHuman-Origin: cli"])

        content.bodyHTML = "<p>Synthetic second pass.</p>"
        try await cli.updateAgentDraft(draft, content: content, note: nil)
        await drainer.drainOnce()
        let second = try #require(try h.store.draft(draft)?.gmailMessageID).rawValue
        #expect(second != first)
        #expect(await h.labelNames(ofMessage: second).contains(OHGmailLabels.agent))
        #expect(lines(try await h.rawOnGmail(second), startingWith: "x-openhuman-origin:") == ["X-OpenHuman-Origin: cli"])
        #expect(await h.gmail.labelIDs(ofMessage: first) == nil)
        #expect(try h.store.reviewQueue(account: h.account).map(\.id) == [draft])
        #expect(try h.store.operations(account: h.account, statuses: [.pending, .inFlight, .failed], limit: 10).isEmpty)
        await #expect(throws: EngineError.sendNotAllowed) {
            _ = try await cli.send(draft, authorization: .userConfirmed, undoWindow: nil)
        }
        #expect(await h.gmail.callCount(.sendDraft) == 0)

        let app = h.engine(factory: FixedGmailFactory(api: probe))
        let receipt = try await app.send(draft, authorization: .userConfirmed, undoWindow: .zero)
        h.advancePast(receipt)
        await drainer.drainOnce()
        #expect(try h.store.operation(receipt.sendOperationID)?.status == .succeeded)
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        try await h.expectOneCleanSentMessage("an agent draft the user sent")
        #expect(lines(try #require(probe.lastUploadBeforeSend), startingWith: "x-openhuman-").isEmpty)
        let sent = try #require(try h.store.draft(draft))
        #expect(sent.state == .sent && sent.origin == .cli && sent.extraHeaders["X-OpenHuman-Origin"] == "cli")
        try cliStore.close()
    }
}
