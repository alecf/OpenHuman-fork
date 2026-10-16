import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import OpenHumanSync
import Testing
@testable import OpenHumanCLIKit

struct FakeFactory: GmailClientFactory {
    let gmail: FakeGmail
    func client(for accountEmail: String) throws -> GmailAPI { gmail }
}

@Suite struct EndToEndTests {
    @Test func aCliDraftGoesToGmailDraftsMarkedAndStaysPendingForReview() async throws {
        let wallMinute = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let clock = TestClock(now: wallMinute)
        let h = try Harness(seed: false)
        let gmail = FakeGmail(accountEmail: h.email, clock: clock, startDate: wallMinute.addingTimeInterval(-86_400))
        _ = await gmail.seedInbox(count: 2)

        let created = await h.run(["gmail", "drafts", "create", "--to", "bob@example.invalid", "--subject", "From the CLI", "--note", "please review",
                                   "--body", "Synthetic text.", "--json"])
        #expect(created.code == 6)
        let draftID = try #require(created.data["draftId"] as? String)
        let upload = try #require(try h.operations([.pending]).first)
        #expect(upload.kind == .upsertDraft && upload.origin == .cli)

        let appStore = try MailStore.open(StoreOptions(location: StoreLocation(directory: h.directory), processKind: .app, appVersion: "0.0.0-test",
                                                       changeNotificationName: "dev.openhuman.test.\(UUID().uuidString)"))
        let drainer = OperationDrainer(account: h.account, store: appStore, api: gmail, clock: clock, ownerID: "test-app")
        let report = await drainer.drainOnce()
        #expect(report.succeeded == 1 && report.failed == 0)
        #expect(try h.store.operation(upload.id)?.status == .succeeded)
        #expect(await gmail.callCount(.createDraft) == 1)
        let stored = try #require(try h.store.draft(DraftID(draftID)))
        let gmailDraftID = try #require(stored.gmailDraftID).rawValue
        let message = try #require(stored.gmailMessageID).rawValue
        let remote = try await gmail.getMessage(id: message, format: .raw, metadataHeaders: [], priority: .sync)
        let raw = String(decoding: Base64URL.decode(try #require(remote.raw)) ?? Data(), as: UTF8.self)
        #expect(raw.contains("X-OpenHuman-Origin: cli"))
        let agentLabel = try #require(await gmail.labelID(named: OHGmailLabels.agent))
        #expect(await gmail.labelIDs(ofMessage: message)?.contains(agentLabel) == true)

        let review = await h.run(["gmail", "review", "list", "--json"])
        #expect(review.code == 0)
        let draft = try #require(review.list("drafts").first)
        #expect(draft["draftId"] as? String == draftID)
        #expect(draft["review"] as? String == "pending" && draft["origin"] as? String == "cli")
        #expect(draft["gmailDraftId"] as? String == gmailDraftID)
        #expect((await h.run(["gmail", "drafts", "get", draftID, "--json"])).data["draftId"] as? String == draftID)
        #expect(draft["reviewLink"] as? String == "openhuman://review?account=\(h.email)&ids=\(draftID)")
        let sendDrafts = await gmail.callCount(.sendDraft), sendMessages = await gmail.callCount(.sendMessage)
        #expect(sendDrafts == 0 && sendMessages == 0)
        #expect(try h.operations().allSatisfy { $0.kind != .sendDraft })
        try appStore.close()
    }
}
