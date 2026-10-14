import Foundation
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailRender
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import OpenHumanSync
import Testing
@testable import OpenHumanMail

private final class HeldGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for c in pending { c.resume() }
    }
}

@MainActor
private func waitFor(_ what: String, timeout: Duration = .seconds(30), _ condition: () async -> Bool,
                     sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while await !condition() {
        if clock.now > deadline {
            Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private final class WriteFixture {
    let corpus: FakeCorpus
    let gmail: FakeGmail
    let running: FakeGmailLaunch.Running
    let store: MailStore
    let directory: URL
    let held = HeldGate()
    var session: SyncSession { running.session }
    var environment: AppEnvironment { running.session.environment }
    var window: AppRouter { environment.router }

    init(threads: Int, safeMode: SafeMode = .normal, sendAs: [GmailSendAs]? = nil) async throws {
        corpus = FakeCorpus.make(threadCount: threads, now: Date())
        gmail = FakeGmail(accountEmail: corpus.account.email)
        if let sendAs { await gmail.setSendAs(sendAs) }
        await FakeGmailLaunch.seed(gmail, corpus: corpus)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-write-port-\(UUID().uuidString)")
        store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .test,
                                                appVersion: "0.0.0-test",
                                                changeNotificationName: "dev.openhuman.tests.writeport.\(UUID().uuidString)"))
        running = try FakeGmailLaunch.makeSession(safeMode: safeMode, store: store, gmail: gmail,
                                                  draftsDirectory: store.location.draftsDirectory)
        await running.session.start()
        window.start()
        let rows = threads
        await eventually("the window's account") { self.window.active != nil }
        window.go(to: .system(.inbox))
        await eventually("inbox rows", timeout: .seconds(60)) { self.window.list?.rows.count == rows }
    }

    lazy var compose: ComposeManager = {
        let manager = environment.compose
        let gate = held
        manager.timing = ComposeTiming(autosaveDelay: .milliseconds(1), discardWindow: .milliseconds(1),
                                       sleep: { duration in
                                           if duration < .seconds(1) { return }
                                           await gate.wait()
                                       })
        return manager
    }()

    func run(_ id: ActionID, in session: ComposeSession) async -> Bool {
        await environment.actions.run(id, source: .keyboard, host: session)
    }

    func run(_ id: ActionID) async -> Bool {
        await environment.actions.run(id, source: .keyboard, host: window)
    }

    func setUndoWindow(_ seconds: Int) async throws {
        try await #require(environment.settings).set(AppSettings.undoSendSeconds, seconds)
    }

    func inInbox(_ thread: GmailThreadID) async -> Bool {
        for id in await gmail.messageIDs(inThread: thread.rawValue) where await gmail.labelIDs(ofMessage: id)?.contains("INBOX") == true {
            return true
        }
        return false
    }

    var writes: [HTTPRequest] { running.wire.requests.filter { !isReadOnlyOnTheWire($0) } }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        held.release()
        window.stop()
        await running.session.stop()
        try? store.close()
        try? FileManager.default.removeItem(at: directory)
    }
    private var stopped = false
}

private func body(_ request: HTTPRequest) -> String {
    String(decoding: request.body ?? Data(), as: UTF8.self)
}

private func document(_ text: String) -> RichTextDocument {
    RichTextDocument(blocks: [.paragraph([.text(text, [])])])
}

@MainActor
@Test(.timeLimit(.minutes(3))) func markDoneAndUndoReachFakeGmailThroughTheEngine() async throws {
    let f = try await WriteFixture(threads: 6)
    defer { Task { await f.stop() } }
    let list = try #require(f.window.list)
    let target = try #require(list.cursor)
    #expect(await f.inInbox(target.gmailThreadID))

    #expect(await f.run(.markDone))
    #expect(list.index(of: target) == nil)
    await waitFor("INBOX removed in FakeGmail") { await !f.inInbox(target.gmailThreadID) }
    #expect(f.environment.notices.toasts.contains { $0.message.hasPrefix("Marked done") })
    #expect(f.environment.status.blockedNotice == nil)

    #expect(await f.run(.undo))
    await waitFor("INBOX back in FakeGmail") { await f.inInbox(target.gmailThreadID) }
    await eventually("the row is back") { list.index(of: target) != nil }

    let writes = f.writes
    #expect(writes.count >= 2)
    #expect(writes.allSatisfy { $0.method == "POST" && ($0.url.path().hasSuffix("/batchModify") || $0.url.path().hasSuffix("/modify")) })
    await f.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aNewMessageSavesWithItsAttachmentUndoesAndSendsThroughTheEngine() async throws {
    let f = try await WriteFixture(threads: 4)
    defer { Task { await f.stop() } }
    let drafts = try #require(f.environment.draftsDirectory)
    #expect(drafts == f.store.location.draftsDirectory, "the composer's folder is the Store's Drafts")
    #expect(f.compose.recovery is FileDraftRecovery)

    let session = try #require(f.compose.openNew(placement: .modal))
    session.to.text = "Dana Ruiz <dana@example.org>,"
    session.subject = "Synthetic plan"
    session.updateBody(document("Synthetic body for the write port."))
    await eventually("draft saved") { session.draftKey != nil && session.saveState == .saved }
    let key = try #require(session.draftKey)
    let row = try #require(try f.store.draft(key))
    #expect(row.origin == .user && row.content.subject == "Synthetic plan")
    #expect(row.content.to.map(\.email) == ["dana@example.org"])
    #expect(row.content.from?.email.lowercased() == f.corpus.account.email.lowercased())
    let recovery = drafts.appendingPathComponent(key.rawValue).appendingPathComponent("draft.json")
    #expect(FileManager.default.fileExists(atPath: recovery.path))
    #expect(try FileManager.default.attributesOfItem(atPath: recovery.path)[.posixPermissions] as? Int == 0o600)

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oh-write-port-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let notes = Data("Synthetic notes for the write port.\n".utf8)
    let source = folder.appendingPathComponent("notes.txt")
    try notes.write(to: source)
    session.attach([source])
    let staged = try #require(session.attachments.first?.localPath)
    #expect(staged == "Drafts/\(key.rawValue)/notes.txt")
    #expect(FileManager.default.fileExists(atPath: f.store.location.directory.appendingPathComponent(staged).path))
    await eventually("saved with the attachment") {
        (try? f.store.draft(key))??.content.attachments.count == 1 && session.saveState == .saved
    }

    #expect(await f.run(.send, in: session))
    #expect(f.compose.heldSendCount == 1 && f.compose.windowSession == nil)
    #expect(try f.store.operations(account: f.session.account, statuses: [.pending], limit: 50).contains { $0.kind == .sendDraft })
    #expect(await f.run(.undo))
    await eventually("the composer is back") { f.compose.windowSession === session }
    #expect(f.compose.heldSendCount == 0 && session.plainText.contains("Synthetic body"))
    #expect(try f.store.operations(account: f.session.account, statuses: [.pending, .inFlight], limit: 50)
        .allSatisfy { $0.kind != .sendDraft })
    #expect(await f.gmail.deliveries().isEmpty, "nothing was sent")

    try await f.setUndoWindow(0)
    #expect(await f.run(.send, in: session))
    await waitFor("FakeGmail delivered it") { await !f.gmail.deliveries().isEmpty }
    let delivery = try #require(await f.gmail.deliveries().first)
    #expect(delivery.recipient == "dana@example.org")
    #expect(String(decoding: delivery.raw, as: UTF8.self).contains("Synthetic plan"))
    let uploads = f.running.wire.requests.filter { $0.url.path().hasPrefix("/upload/gmail/v1/users/me/drafts") }
    #expect(uploads.contains { body($0).contains("notes.txt") && body($0).contains(notes.base64EncodedString()) },
            "the staged file went up with the draft")
    #expect(f.running.wire.requests.filter { $0.url.path() == "/gmail/v1/users/me/drafts/send" }.count == 1)
    await eventually("Sent.") { f.environment.notices.toasts.contains { $0.message == "Sent." } }
    await eventually("the draft's folder is gone") {
        !FileManager.default.fileExists(atPath: drafts.appendingPathComponent(key.rawValue).path)
    }
    #expect(await f.gmail.deliveries().count == 1, "sent exactly once")
    await f.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aReplyGetsTheEnginesSkeletonAndLandsInItsThread() async throws {
    let f = try await WriteFixture(threads: 5)
    defer { Task { await f.stop() } }
    let me = f.corpus.account.email
    let source = try #require(f.corpus.threads.first {
        guard let last = $0.detail.messages.last?.from?.email else { return false }
        return last != me
    })
    let sender = try #require(source.detail.messages.last?.from?.email)
    let row = try #require(f.window.list?.rows.first { $0.subject == source.detail.subject })

    let session = try #require(f.compose.openReply(row.id, mode: .reply))
    await eventually("the skeleton") { session.draftKey != nil && !session.isPreparing && !session.to.tokens.isEmpty }
    #expect(session.to.tokens.map { $0.email.lowercased() } == [sender.lowercased()])
    #expect(session.subject.hasPrefix("Re: ") && !session.quotedHTML.isEmpty)
    #expect(QuoteSplit.quoteBlockCount(session.assembledFields().bodyHTML) == 1, "one quote block")
    let key = try #require(session.draftKey)
    #expect(try f.store.draft(key)?.composeMode == .reply)

    session.updateBody(document("Synthetic reply."))
    try await f.setUndoWindow(0)
    #expect(await f.run(.send, in: session))
    await waitFor("FakeGmail delivered the reply") { await !f.gmail.deliveries().isEmpty }
    let delivery = try #require(await f.gmail.deliveries().first)
    #expect(delivery.recipient == sender.lowercased())
    #expect(await f.gmail.messageIDs(inThread: row.id.gmailThreadID.rawValue).contains(delivery.sentMessageID),
            "the sent copy is in the conversation")
    await f.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func sendLaterAndDiscardReachTheGmailDraftThroughTheEngine() async throws {
    let f = try await WriteFixture(threads: 3)
    defer { Task { await f.stop() } }
    let commands = try #require(f.environment.commands)
    let session = try #require(f.compose.openNew(placement: .modal))
    session.to.text = "sam@example.org,"
    session.subject = "Synthetic later"
    session.updateBody(document("Synthetic text to send later."))
    await eventually("draft saved") { session.draftKey != nil && session.saveState == .saved }
    let key = try #require(session.draftKey)

    let at = Date().addingTimeInterval(3_600)
    try await commands.scheduleSend(key, at: at)
    let scheduled = try #require(try f.store.draft(key))
    #expect(scheduled.state == .scheduled && scheduled.sendAt != nil)
    await waitFor("the schedule reached the Gmail draft") {
        f.running.wire.requests.contains { $0.url.path().hasPrefix("/upload/gmail/v1/users/me/drafts")
            && body($0).contains("X-OpenHuman-Send-At") }
    }
    let summary = try #require(try await firstValue(f.environment.data.draft(key)) { $0?.status == .scheduled })
    #expect(summary.sendAt != nil, "\"Sends at\" is read back from the row")

    try await commands.cancelScheduledSend(key)
    #expect(try f.store.draft(key)?.state == .editing)
    await waitFor("the Gmail draft exists") { (try? f.store.draft(key))??.gmailDraftID != nil }
    let gmailDraft = try #require(try f.store.draft(key)?.gmailDraftID)

    #expect(await f.run(.discardDraft, in: session))
    await waitFor("the Gmail draft is deleted") {
        f.running.wire.requests.contains { $0.method == "DELETE" && $0.url.path().hasSuffix("/drafts/\(gmailDraft.rawValue)") }
    }
    #expect(try await firstValue(f.environment.data.draft(key)) == nil, "the port reports the draft gone")
    #expect(await f.gmail.deliveries().isEmpty, "nothing was sent")
    await f.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func theSignatureAndAnUnverifiedAliasReachTheComposer() async throws {
    let me = FakeCorpus.make(threadCount: 1, now: Date()).account.email
    let f = try await WriteFixture(threads: 3, safeMode: .readOnly, sendAs: [
        GmailSendAs(sendAsEmail: me, displayName: "Robin Example", signature: "<div>Robin Example<br>Example Co.</div>",
                    isPrimary: true, isDefault: true, verificationStatus: "accepted"),
        GmailSendAs(sendAsEmail: "robin@relay.example", displayName: "Robin (Relay)", isDefault: false,
                    verificationStatus: "pending"),
    ])
    defer { Task { await f.stop() } }
    #expect(f.environment.draftsDirectory == nil, "read-only: the composer keeps nothing under the Store")
    let account = try #require(try await firstValue(f.environment.data.accounts()) { $0.first?.sendAs.count == 2 }.first)
    #expect(account.sendAs.map(\.needsVerification) == [false, true])

    let session = try #require(f.compose.openNew(placement: .modal))
    await session.settle()
    #expect(session.from.email == me.lowercased() && session.signature?.html == "<div>Robin Example<br>Example Co.</div>")
    let relay = try #require(session.fromChoices.first { $0.email == "robin@relay.example" })
    #expect(relay.needsVerification, "shown, flagged, never picked on its own")
    #expect(!session.canPersist, "read-only: the composer saves nothing")
    #expect(f.running.wire.requests.allSatisfy(isReadOnlyOnTheWire))
    #expect(f.running.wire.requests.contains { $0.url.path().hasSuffix("/settings/sendAs") })
    await f.stop()
}

@MainActor
@Test(.timeLimit(.minutes(3))) func aReadOnlyReplyIsPrefilledFromTheSkeletonWithoutWriting() async throws {
    let f = try await WriteFixture(threads: 5, safeMode: .readOnly)
    defer { Task { await f.stop() } }
    let me = f.corpus.account.email
    let source = try #require(f.corpus.threads.first {
        guard let last = $0.detail.messages.last?.from?.email else { return false }
        return last != me
    })
    let sender = try #require(source.detail.messages.last?.from?.email)
    let row = try #require(f.window.list?.rows.first { $0.subject == source.detail.subject })

    let session = try #require(f.compose.openReply(row.id, mode: .reply))
    await eventually("the skeleton") { !session.isPreparing && !session.to.tokens.isEmpty }
    #expect(session.to.tokens.map { $0.email.lowercased() } == [sender.lowercased()])
    #expect(session.subject.hasPrefix("Re: ") && QuoteSplit.quoteBlockCount(session.quotedHTML) == 1)
    #expect(QuotePreview(quotedText: session.quotedText, quotedHTML: session.quotedHTML).header.hasSuffix("wrote:"))
    #expect(session.draftKey == nil && !session.canPersist)
    #expect(try f.store.drafts(account: nil, states: [.editing, .scheduled, .failed, .sending], limit: 50).isEmpty,
            "no draft row")
    #expect(f.writes.isEmpty && f.running.wire.requests.allSatisfy(isReadOnlyOnTheWire))
    f.compose.close(session)
    await f.stop()
}
