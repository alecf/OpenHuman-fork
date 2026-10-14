import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct EngineWiringTests {
    @Test func maintenanceIsThrottledAndRunsAGarbageCollectingPass() async throws {
        let h = try await EngineHarness(safeMode: .readOnly, scopes: [GmailScope.readonly], stack: false)
        defer { h.cleanup() }
        let engine = h.engine(safeMode: .readOnly)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(await engine.maintenanceDue(now: t0))
        #expect(await engine.maintenanceDue(now: t0.addingTimeInterval(MailEngine.maintenanceEvery - 1)) == false)
        #expect(await engine.maintenanceDue(now: t0.addingTimeInterval(MailEngine.maintenanceEvery)))
        let report = MailEngine.maintenancePass(h.store, now: Date().addingTimeInterval(120))
        #expect(report != nil)
    }

    @Test func concurrentBodyAsksForOneConversationShareOneThreadFetch() async throws {
        let h = try await EngineHarness(safeMode: .readOnly, scopes: [GmailScope.readonly], stack: false, threads: 0)
        defer { h.cleanup() }
        let first = await h.gmail.deliver(subject: "Long thread", body: "Text one")
        var ids = [first.messageID]
        for index in 2...5 { ids.append(await h.gmail.deliver(subject: "Re: Long thread", body: "Text \(index)", threadID: first.threadID).0) }
        let solo = await h.gmail.deliver(subject: "Solo", body: "Alone")
        let engine = h.engine(safeMode: .readOnly)
        _ = try await engine.fetchThread(account: h.account, gmailThreadID: GmailThreadID(first.threadID))
        _ = try await engine.fetchThread(account: h.account, gmailThreadID: GmailThreadID(solo.threadID))
        for id in ids { #expect(try h.store.message(account: h.account, gmailMessageID: GmailMessageID(id))?.bodyState != .stored) }

        await h.gmail.resetAccounting()
        let account = h.account
        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for id in ids { group.addTask { try await engine.ensureBody(account: account, gmailMessageID: GmailMessageID(id)) } }
            var all: [Bool] = []
            for try await value in group { all.append(value) }
            return all
        }
        #expect(results.count == 5 && results.allSatisfy { $0 })
        #expect(await h.gmail.callLog == [.getThread])
        for id in ids { #expect(try h.store.message(account: h.account, gmailMessageID: GmailMessageID(id))?.bodyState == .stored) }

        await h.gmail.resetAccounting()
        #expect(try await engine.ensureBody(account: h.account, gmailMessageID: GmailMessageID(solo.messageID)))
        #expect(await h.gmail.callLog == [.getMessage])
    }

    @Test func theRowIDFormsFetchABodyAndAnAttachmentWithGETsOnly() async throws {
        let h = try await EngineHarness(safeMode: .readOnly, scopes: [GmailScope.readonly], stack: true)
        defer { h.cleanup() }
        let pdf = Data("%PDF-1.4 synthetic attachment bytes".utf8)
        let delivered = await h.gmail.deliver(
            subject: "Report", body: "Synthetic report body.",
            attachments: [FakeGmailAttachment(filename: "report.pdf", mimeType: "application/pdf", data: pdf)])
        let engine = h.engine(safeMode: .readOnly)

        let ref = try #require(try await engine.fetchThread(account: h.account,
                                                             gmailThreadID: GmailThreadID(delivered.threadID)))
        let messageID = GmailMessageID(delivered.messageID)
        let stored = try #require(try h.store.message(account: h.account, gmailMessageID: messageID))
        #expect(stored.id.rawValue > 0 && ref.accountID == h.account)
        #expect(try h.store.body(stored.id) == nil)

        try await engine.ensureBody(message: stored.id)
        let body = try #require(try h.store.body(stored.id))
        #expect(body.text?.contains("Synthetic report body.") == true)
        try await engine.ensureBody(message: stored.id)

        let attachment = try #require(try h.store.message(account: h.account, gmailMessageID: messageID)?
            .attachments.first { $0.filename == "report.pdf" })
        let file = try await engine.attachmentFile(attachment.id)
        #expect(try Data(contentsOf: file) == pdf)
        #expect(try await engine.attachmentFile(attachment.id) == file)

        await #expect(throws: StoreError.self) { try await engine.ensureBody(message: MessageRowID(rawValue: 999_999)) }
        await #expect(throws: StoreError.self) { _ = try await engine.attachmentFile(999_999) }

        let wire = try #require(h.wire)
        #expect(!wire.requests.isEmpty)
        #expect(wire.nonGETRequests.isEmpty)
        #expect(await h.gmail.callCount(.getAttachment) == 1)
    }

    @Test func theProgressHubFollowsEachRuntimeAndForgetsItOnStop() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        var updates = engine.observeSyncProgress().makeAsyncIterator()
        #expect(await updates.next() == [:])
        #expect(engine.syncProgress(h.account) == nil)

        await engine.start()
        try await h.waitForSyncs(engine)
        let runtime = try #require(await engine.runtime(for: h.account))
        try await eventually("the hub carries the syncer's progress") {
            engine.syncProgress(h.account) == runtime.syncer.progress
        }
        var seen: [AccountID: SyncProgress]?
        while let next = await updates.next() {
            seen = next
            if next[h.account] != nil { break }
        }
        #expect(seen?[h.account] != nil)

        await engine.stop()
        #expect(engine.syncProgress(h.account) == nil)
    }
}
