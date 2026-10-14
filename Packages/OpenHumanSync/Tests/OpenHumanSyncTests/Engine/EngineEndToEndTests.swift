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
        let factory = DefaultGmailClientFactory(safeMode: .normal, tokenStore: tokens, oauthClient: FakeGoogleSignIn.client,
                                                apiTransport: wire, tokenTransport: google.transport,
                                                config: engineGmailConfig, clock: clock)
        let store = try MailStore.openInMemoryForTesting()
        let engine = MailEngine(store: store, gmailFactory: factory, tokenStore: tokens, oauthClient: FakeGoogleSignIn.client,
                                configuration: EngineConfiguration(role: .app, appVersion: "0.0.0-test",
                                                                   gmail: engineGmailConfig, clock: clock),
                                systemEvents: nil)
        await engine.start()

        let account = try await engine.addAccount(using: google.flow(.normal), loginHint: nil)
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

    @Test func aLocalClientsAgentDraftReachesGmailOnlyAfterTheUserReviewsIt() async throws {
        let h = try await EngineHarness(onDisk: true)
        defer { h.cleanup() }
        let directory = try #require(h.directory)
        let cliStore = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .cli,
                                                       appVersion: "0.0.0-test",
                                                       changeNotificationName: "dev.openhuman.test.\(UUID().uuidString)"))
        let cli = h.engine(role: .localClient, factory: .some(nil), store: cliStore)
        let content = DraftContent(to: [EmailAddress(email: "bob@example.invalid")], cc: [], bcc: [], subject: "From an agent",
                                   bodyHTML: "<p>Synthetic agent text.</p>", attachments: [])
        let draft = try await cli.createAgentDraft(account: h.account, mode: .new, replyTo: nil, content: content,
                                                   note: "please review", origin: .cli)
        let upload = try #require(try h.store.operations(account: h.account, statuses: [.pending], limit: 10).first)
        #expect(upload.kind == .upsertDraft && upload.origin == .cli)
        #expect(try h.store.lease(account: h.account) == nil)

        let app = h.engine()
        await app.start()
        try await eventually("the app's drainer refused it") { try h.store.operation(upload.id)?.status == .failed }
        #expect(try h.store.operation(upload.id)?.lastErrorCode == "safe_mode_blocked")
        #expect(await h.gmail.callCount(.createDraft) == 0)
        #expect(await h.gmail.callCount(.updateDraft) == 0)
        #expect(try h.store.reviewQueue(account: h.account).map(\.id) == [draft])
        #expect(try h.store.draft(draft)?.gmailDraftID == nil)

        try await app.setReviewState(draft, .approved)
        try await app.flushDraft(draft)
        try await eventually("uploaded after review") { try h.store.draft(draft)?.gmailDraftID != nil }
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        await app.stop()
        try cliStore.close()
    }
}
