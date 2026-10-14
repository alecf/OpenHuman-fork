import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct SafeModeSendTests {
    @Test func readOnlyRefusesTheUploadAndTheSendBeforeTheWire() async throws {
        let h = try await WriteHarness(safeMode: .readOnly, clock: sendClock())
        let events = EventLog()
        let drainer = h.drainer(api: try h.client, events: events)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        h.advancePast(receipt)
        let report = await drainer.drainOnce()
        #expect(report.failed == 1 && report.retried == 0)
        let uploadID = try #require(receipt.upsertOperationID)
        let upload = try #require(try h.store.operation(uploadID))
        #expect(upload.status == .failed && upload.lastErrorCode == "safe_mode_blocked")
        let send = try #require(try h.store.operation(receipt.sendOperationID))
        #expect(send.status == .failed && send.lastErrorCode == "dependency_failed")
        #expect(try h.draft(id).state == .failed)
        #expect(events.failedOperations.map(\.id) == [upload.id] && events.sendFailures.map(\.0) == [id])
        #expect(h.wire.nonGETRequests.isEmpty)
        #expect(try await h.sentOnGmail().isEmpty)
        #expect(try await h.gmailDraftIDs().isEmpty)
        h.instant.advance(by: .seconds(3600))
        #expect(await drainer.drainOnce().claimed == 0)
        #expect(h.wire.nonGETRequests.isEmpty)
    }

    @Test func writeAllowlistSavesTheAppsOwnDraftButNeverSends() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let transport = SafeModeTransport.wrap(h.wire, mode: .writeAllowlist, grantedScopes: [GmailScope.modify],
                                               allowlist: WriteAllowlistStore(accountEmail: "me@example.com"))
        let client = GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(), transport: transport,
                                 config: GmailClientConfig(userAgent: "OpenHumanMail/test"), clock: h.clock, metrics: nil)
        let events = EventLog()
        let drainer = h.drainer(api: client, events: events)
        let id = try h.newDraft()
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        h.advancePast(receipt)
        await drainer.drainOnce()
        let uploadID = try #require(receipt.upsertOperationID)
        #expect(try h.store.operation(uploadID)?.status == .succeeded)
        let send = try #require(try h.store.operation(receipt.sendOperationID))
        #expect(send.status == .failed && send.lastErrorCode == "safe_mode_blocked")
        #expect(send.lastErrorMessage?.contains("drafts/send") == true)
        #expect(try h.draft(id).state == .failed)
        #expect(events.sendFailures.map(\.0) == [id])
        #expect(await h.gmail.callCount(.sendDraft) == 0)
        #expect(!h.wire.requests.contains { $0.url.path().hasSuffix("/drafts/send") })
        #expect(try await h.sentOnGmail().isEmpty)
        #expect(try await h.gmailDraftIDs().count == 1)
    }
}
