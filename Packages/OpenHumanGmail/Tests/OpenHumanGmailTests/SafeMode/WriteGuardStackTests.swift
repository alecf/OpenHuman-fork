import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

@Suite struct WriteGuardStackTests {
    private struct Stack {
        let gmail: FakeGmail
        let wire: FakeGmailWire
        let store: WriteAllowlistStore
        let client: GmailClient
    }

    private func stack(mode: SafeMode = .writeAllowlist) -> Stack {
        let clock = InstantClock()
        let gmail = FakeGmail(clock: clock)
        let wire = FakeGmailWire(gmail)
        let store = WriteAllowlistStore(accountEmail: "me@example.com")
        let transport = SafeModeTransport.wrap(wire, mode: mode, grantedScopes: [GmailScope.modify], allowlist: store)
        let client = GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(), transport: transport,
                                 config: GmailClientConfig(userAgent: "OpenHumanMail/test"), clock: clock, metrics: nil,
                                 limiter: QuotaLimiter(unitsPerMinute: 1_000_000, maxConcurrent: 8, clock: clock),
                                 jitter: { 0 })
        return Stack(gmail: gmail, wire: wire, store: store, client: client)
    }

    private func expectBlocked(_ what: String, sourceLocation: SourceLocation = #_sourceLocation,
                               _ call: () async throws -> Void) async {
        do {
            try await call()
            Issue.record("\(what) passed", sourceLocation: sourceLocation)
        } catch GmailError.transport(.blockedBySafeMode) {
        } catch {
            Issue.record("\(what): unexpected \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func rungTwoHarnessTouchesOnlyWhatItCreated() async throws {
        let s = stack()
        let gmail = s.gmail, client = s.client
        let real = await gmail.seedInbox(count: 5)
        let work = await gmail.addUserLabel("Work")
        let realDraft = try await gmail.createDraft(rawRFC822: Data("Subject: mine\r\n\r\nhello".utf8), threadID: real[0])
        await gmail.resetAccounting()

        let harness = try SyntheticThreads(api: client, runID: "20261010T1200Z-ab12")
        let inserted = try await harness.insertThreads(count: 3, date: Date(timeIntervalSince1970: 1_790_000_000))
        let reply = try await harness.insertReply(to: inserted[0], index: 4, date: Date(timeIntervalSince1970: 1_790_000_060))
        let testLabel = try #require(await gmail.labelID(named: OHGmailLabels.test))
        for message in inserted {
            #expect(await gmail.labelIDs(ofMessage: message.messageID) == [testLabel, "INBOX", "UNREAD"])
        }
        #expect(await s.store.snapshot.testLabelID == testLabel)

        try await client.batchModifyMessages(ids: inserted.map(\.messageID), add: ["STARRED"], remove: ["UNREAD"])
        let wake = try await client.createLabel(name: "OpenHuman/Snoozed/20261012T0900Z", labelListVisibility: "labelHide",
                                                messageListVisibility: "hide")
        let marker = try await client.createLabel(name: OHGmailLabels.snoozed, labelListVisibility: "labelHide",
                                                  messageListVisibility: "hide")
        _ = try await client.modifyMessage(id: inserted[1].messageID, add: [wake.id, marker.id], remove: ["INBOX"])
        _ = try await client.trashThread(id: inserted[2].threadID)
        _ = try await client.untrashThread(id: inserted[2].threadID)
        let draft = try await client.createDraft(rawRFC822: Data("Subject: reply\r\n\r\ndraft".utf8),
                                                 threadID: inserted[0].threadID)
        let updated = try await client.updateDraft(id: draft.id, rawRFC822: Data("Subject: reply\r\n\r\nedited".utf8),
                                                   threadID: inserted[0].threadID)
        let ownDraft = try await client.createDraft(rawRFC822: Data("Subject: new\r\n\r\nnew".utf8), threadID: nil)
        try await client.deleteDraft(id: draft.id)
        #expect(await gmail.labelIDs(ofMessage: inserted[1].messageID)?.contains(wake.id) == true)
        #expect(await s.store.snapshot.containsMessage(updated.message?.id ?? "-"))

        let wireBefore = s.wire.requests.count
        let realMessage = real[0]
        await expectBlocked("batchModify of real mail") {
            try await client.batchModifyMessages(ids: [realMessage], add: [], remove: ["INBOX"])
        }
        await expectBlocked("batchModify mixing test and real ids") {
            try await client.batchModifyMessages(ids: [inserted[0].messageID, realMessage], add: [], remove: ["INBOX"])
        }
        await expectBlocked("trash of a real thread") { _ = try await client.trashThread(id: real[1]) }
        await expectBlocked("modify of a real message") { _ = try await client.modifyMessage(id: real[2], add: ["STARRED"], remove: []) }
        await expectBlocked("a user label on a test message") {
            _ = try await client.modifyMessage(id: inserted[0].messageID, add: [work], remove: [])
        }
        await expectBlocked("a user label") { _ = try await client.createLabel(name: "Work 2", labelListVisibility: nil, messageListVisibility: nil) }
        await expectBlocked("a draft in a real thread") { _ = try await client.createDraft(rawRFC822: Data("x".utf8), threadID: real[0]) }
        await expectBlocked("update of a real draft") { _ = try await client.updateDraft(id: realDraft.id, rawRFC822: Data("x".utf8), threadID: nil) }
        await expectBlocked("delete of a real draft") { try await client.deleteDraft(id: realDraft.id) }
        await expectBlocked("send of the run's own draft") { _ = try await client.sendDraft(id: ownDraft.id) }
        await expectBlocked("send of a real draft") { _ = try await client.sendDraft(id: realDraft.id) }
        await expectBlocked("send into a test thread") {
            _ = try await client.sendMessage(rawRFC822: SyntheticThreads.message(runID: "r", index: 9, to: "me@example.com",
                                                                                 date: Date()), threadID: inserted[0].threadID)
        }
        await expectBlocked("insert of real-looking mail") {
            _ = try await client.insertMessage(rawRFC822: Data("From: alice@example.com\r\nSubject: hi\r\n\r\nx".utf8),
                                               labelIDs: [testLabel, "INBOX"])
        }
        await expectBlocked("insert without the Test label") {
            _ = try await client.insertMessage(rawRFC822: SyntheticThreads.message(runID: "r", index: 9, to: "me@example.com",
                                                                                   date: Date()), labelIDs: ["INBOX"])
        }
        #expect(s.wire.requests.count == wireBefore)
        for message in real {
            #expect(await gmail.labelIDs(ofMessage: message) == ["INBOX", "UNREAD"])
        }
        #expect(try await gmail.getDraft(id: realDraft.id, format: .minimal).id == realDraft.id)
        #expect(try await gmail.getDraft(id: ownDraft.id, format: .minimal).id == ownDraft.id)
        #expect(await gmail.callCount(.sendMessage) == 0)
        #expect(await gmail.callCount(.sendDraft) == 0)

        try await harness.cleanUp(inserted + [reply])
        for message in inserted + [reply] {
            let labels = await gmail.labelIDs(ofMessage: message.messageID) ?? []
            #expect(labels.contains("TRASH") && !labels.contains("INBOX"))
        }
        let own = await s.store.snapshot
        let realIDs = Set(real).union([realDraft.id, work])
        for request in s.wire.nonGETRequests {
            let segments = Set(request.url.path().split(separator: "/").map(String.init))
            #expect(segments.isDisjoint(with: realIDs), "\(request.method) \(request.url.path())")
            if let body = request.body.map({ String(decoding: $0, as: UTF8.self) }) {
                for id in realIDs { #expect(!body.contains("\"\(id)\""), "\(request.url.path())") }
            }
        }
        #expect(own.threadIDs == Set((inserted + [reply]).map(\.threadID)))
        #expect(own.draftIDs == [draft.id, ownDraft.id])
        #expect(s.wire.requests.allSatisfy { !$0.url.path().contains("send") })
        #expect(s.wire.requests.filter { $0.method == "DELETE" }.map { $0.url.path() }
                == ["/gmail/v1/users/me/drafts/\(draft.id)"])
    }

    @Test func rungOneRefusesTheHarnessItself() async throws {
        let s = stack(mode: .readOnly)
        let harness = try SyntheticThreads(api: s.client, runID: "run1")
        await expectBlocked("insert in read-only mode") { _ = try await harness.insertThreads(count: 1) }
        #expect(s.wire.nonGETRequests.isEmpty)
        #expect(await s.gmail.messageCount == 0)
    }

    @Test func fakeGmailTransportUploads() async throws {
        let clock = InstantClock()
        let gmail = FakeGmail(clock: clock)
        let client = GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(),
                                 transport: FakeGmailTransport(gmail), config: GmailClientConfig(userAgent: "t"),
                                 clock: clock, metrics: nil,
                                 limiter: QuotaLimiter(unitsPerMinute: 1_000_000, maxConcurrent: 8, clock: clock),
                                 jitter: { 0 })
        let inserted = try await client.insertMessage(rawRFC822: WG.synthetic, labelIDs: ["INBOX"])
        #expect(await gmail.labelIDs(ofMessage: inserted.id)?.contains("INBOX") == true)
        let draft = try await client.createDraft(rawRFC822: WG.synthetic, threadID: nil)
        #expect(!draft.id.isEmpty)
    }

    @Test func harnessShapes() throws {
        #expect(throws: SyntheticThreads.Failure.invalidRunID) { _ = try SyntheticThreads(api: FakeGmail(), runID: "") }
        #expect(throws: SyntheticThreads.Failure.invalidRunID) { _ = try SyntheticThreads(api: FakeGmail(), runID: "a b") }
        #expect(throws: SyntheticThreads.Failure.invalidRunID) { _ = try SyntheticThreads(api: FakeGmail(), runID: "-x") }
        #expect(throws: SyntheticThreads.Failure.invalidRunID) {
            _ = try SyntheticThreads(api: FakeGmail(), runID: String(repeating: "a", count: 41))
        }
        let runID = SyntheticThreads.makeRunID(now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(SyntheticThreads.isValidRunID(runID) && runID.hasPrefix("20260921T"))
        let raw = SyntheticThreads.message(runID: "run1", index: 2, subjectIndex: 1, to: "me@example.com",
                                           date: Date(timeIntervalSince1970: 1_790_000_000),
                                           inReplyTo: "<oh-test.run1.1@openhuman.invalid>")
        let text = String(decoding: raw, as: UTF8.self)
        #expect(text.hasPrefix("From: OpenHuman Test <test@openhuman.invalid>\r\nTo: me@example.com\r\n"))
        #expect(text.contains("\r\nSubject: [OpenHuman test] run1 1\r\n"))
        #expect(text.contains("\r\nMessage-ID: <oh-test.run1.2@openhuman.invalid>\r\n"))
        #expect(text.contains("\r\nIn-Reply-To: <oh-test.run1.1@openhuman.invalid>\r\nReferences: <oh-test.run1.1@openhuman.invalid>\r\n"))
        #expect(text.contains("\r\nDate: Mon, 21 Sep 2026"))
        #expect(text.utf8.allSatisfy { $0 < 0x80 })
        #expect(SyntheticHeaders.refusal(raw) == nil)
    }
}
