import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct RemoteSearchTests {
    @Test func gmailFindsOldMailTheStoreLacksAndReturnsThreadsInGmailsOrder() async throws {
        let h = try SyncHarness(recording: true)
        let recorder = try #require(h.recorder)
        let label = await h.gmail.addUserLabel("Receipts")
        let day: TimeInterval = 86_400
        let old1 = await h.gmail.deliver(subject: "Old receipt 1", labels: [label], date: testNow.addingTimeInterval(-400 * day))
        let old2 = await h.gmail.deliver(subject: "Old receipt 2", labels: [label], date: testNow.addingTimeInterval(-300 * day))
        await h.gmail.deliver(subject: "Old other", labels: ["CATEGORY_UPDATES"], date: testNow.addingTimeInterval(-350 * day))
        let recent = await h.gmail.deliver(subject: "New receipt", labels: ["INBOX", label],
                                           date: testNow.addingTimeInterval(-day))
        try await h.syncer.sync(reason: "launch")
        #expect(try h.message(old1.messageID) == nil)

        let query = try h.store.parseSearch("label:receipts")
        let page = try h.store.search(query, accounts: [h.account], after: nil, limit: 20)
        #expect(page.completeness.needsGmailFallback && page.completeness.gmailQuery == query.gmailQuery)
        recorder.reset()
        let search = RemoteSearch(account: h.account, store: h.store, api: recorder)
        let refs = try await search.search(query)
        #expect(refs.map(\.gmailThreadID.rawValue) == [recent.threadID, old2.threadID, old1.threadID])
        #expect(try h.message(old1.messageID)?.subject == "Old receipt 1")
        #expect(recorder.calls(.listMessages).count == 1 && recorder.calls(.getThread).map(\.items) == [2])
        #expect(recorder.calls.allSatisfy { $0.priority == .interactive })

        recorder.reset()
        #expect(try await search.search(gmailQuery: query.gmailQuery).count == 3)
        #expect(recorder.calls(.getThread).isEmpty)
        #expect(try await search.search(gmailQuery: "   ").isEmpty)
    }
}
