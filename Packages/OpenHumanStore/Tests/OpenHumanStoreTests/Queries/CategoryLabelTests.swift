import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct CategoryLabelTests {
    private func rid(_ f: AggregationFixture, _ key: String) throws -> LabelRowID {
        try #require(try f.store.label(account: f.account, key: key)).id
    }

    @Test func listReadsCarryTheThreadsCategoriesAndNotItsOtherLabels() throws {
        let f = try AggregationFixture()
        try f.labels([("Label_1", "Clients")])
        try f.upsert([
            .fixture("p", thread: "tp", minutes: 1, labels: ["INBOX", "CATEGORY_PROMOTIONS", "Label_1"]),
            .fixture("u1", thread: "tu", minutes: 2, labels: ["INBOX", "CATEGORY_UPDATES"]),
            .fixture("u2", thread: "tu", minutes: 3, labels: ["INBOX", "CATEGORY_PERSONAL", "UNREAD"]),
            .fixture("n", thread: "tn", minutes: 4, labels: ["INBOX"]),
        ])
        let promotions = try rid(f, "CATEGORY_PROMOTIONS")
        let updates = try rid(f, "CATEGORY_UPDATES")
        let personal = try rid(f, "CATEGORY_PERSONAL")
        let clients = try rid(f, "Label_1")
        let expected: [String: [LabelRowID]] = [
            "tp": [promotions], "tu": [personal, updates].sorted { $0.rawValue < $1.rawValue }, "tn": [],
        ]

        let page = try f.store.threadPage(view: .system(f.account, .inbox), after: nil, limit: 10)
        #expect(page.items.count == 3)
        for item in page.items {
            #expect(item.categoryLabelIDs == expected[item.ref.gmailThreadID.rawValue], "\(item.ref.gmailThreadID)")
        }
        #expect(page.items.first { $0.ref.gmailThreadID.rawValue == "tp" }?.userLabelIDs == [clients])

        let window = try f.store.read { db in try MailStore.window(view: .system(f.account, .inbox), limit: 10, in: db) }
        #expect(window.items.map(\.categoryLabelIDs) == page.items.map(\.categoryLabelIDs))

        let single = try #require(try f.store.thread(try f.ref("tu")))
        #expect(single.categoryLabelIDs == expected["tu"])
        let detail = try #require(try f.store.threadDetail(ThreadRowID(rawValue: try f.tid("tp"))))
        #expect(detail.thread.categoryLabelIDs == [promotions])
    }

    @Test func theLiveWindowObservationFollowsACategoryChange() async throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("a", thread: "ta", labels: ["INBOX", "CATEGORY_SOCIAL"])])
        let social = try rid(f, "CATEGORY_SOCIAL")
        let forums = try rid(f, "CATEGORY_FORUMS")
        let observation = f.store.observeThreadList(view: .system(f.account, .inbox), limit: 10)
        var iterator = observation.values().makeAsyncIterator()
        #expect(try await iterator.next()?.items.first?.categoryLabelIDs == [social])
        _ = try f.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("a"), historyID: HistoryID(5),
                                                     added: [GmailLabelID("CATEGORY_FORUMS")],
                                                     removed: [GmailLabelID("CATEGORY_SOCIAL")])],
                                         account: f.account)
        var latest: [LabelRowID]?
        while let window = try await iterator.next() {
            latest = window.items.first?.categoryLabelIDs
            if latest == [forums] { break }
        }
        #expect(latest == [forums])
    }

    @Test func aCategoryWithoutALabelRowIsLeftOut() throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        try store.upsertLabels([LabelUpsert(gmailLabelID: GmailLabelID("INBOX"), name: "INBOX", type: "system")], account: account,
                               removeMissing: false)
        _ = try store.upsertMessages([.fixture("a", labels: ["INBOX", "CATEGORY_UPDATES"])], account: account, generation: 1)
        let page = try store.threadPage(view: .system(account, .inbox), after: nil, limit: 10)
        #expect(page.items.count == 1)
        #expect(page.items[0].categoryLabelIDs.isEmpty)
    }

    @Test func theCategoryReadIsIndexed() throws {
        let f = try AggregationFixture()
        try f.upsert((0..<40).map { .fixture("m\($0)", minutes: $0, labels: ["INBOX", "CATEGORY_UPDATES"]) })
        let found = try plans(f.store) { db in
            _ = try MailStore.window(view: .system(f.account, .inbox), limit: 40, in: db)
        }
        #expect(found.contains { $0.sql.contains("FROM thread_labels") && $0.sql.contains("label_rid IN") })
        expectIndexed(found)
    }
}
