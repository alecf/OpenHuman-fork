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
    @Test func aCliDraftIsNotUploadedByTheAppAndStaysPendingForReview() async throws {
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
        let app = MailEngine(store: appStore, gmailFactory: FakeFactory(gmail: gmail), tokenStore: nil, oauthClient: nil,
                             configuration: EngineConfiguration(role: .app, appVersion: "0.0.0-test", gmail: GmailClientConfig(userAgent: "t"),
                                                                clock: clock, schedulers: []), systemEvents: nil)
        await app.start()
        var refused = false
        for _ in 0..<7_500 {
            if try h.store.operation(upload.id)?.status == .failed { refused = true; break }
            try await Task.sleep(for: .milliseconds(4))
        }
        #expect(refused, "the app's drainer did not refuse the CLI draft within 30 s")
        #expect(try h.store.operation(upload.id)?.lastErrorCode == "not_applied_outside_app")
        #expect(await gmail.callCount(.createDraft) == 0)

        let review = await h.run(["gmail", "review", "list", "--json"])
        #expect(review.code == 0)
        let draft = try #require(review.list("drafts").first)
        #expect(draft["draftId"] as? String == draftID)
        #expect(draft["review"] as? String == "pending" && draft["origin"] as? String == "cli")
        #expect(draft["gmailDraftId"] as? String == nil)
        #expect((await h.run(["gmail", "drafts", "get", draftID, "--json"])).data["draftId"] as? String == draftID)
        #expect(draft["reviewLink"] as? String == "openhuman://review?account=\(h.email)&ids=\(draftID)")
        let sendDrafts = await gmail.callCount(.sendDraft), sendMessages = await gmail.callCount(.sendMessage)
        #expect(sendDrafts == 0 && sendMessages == 0)
        #expect(try h.operations().allSatisfy { $0.kind != .sendDraft })
        await app.stop()
        try appStore.close()
    }
}
