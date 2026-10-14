import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanStore

@Suite struct SnippetObservationTests {
    @Test func theSnippetListIsLiveAndMatchesTheRead() async throws {
        let f = try AggregationFixture()
        let other = try f.store.addAccount(email: "other@example.com", displayName: nil, scopes: ["gmail.readonly"])
        let list = Collector(f.store.observeSnippets(account: f.account))
        try #require(await list.waitForCount(1))
        #expect(list.values[0].isEmpty)

        try f.store.upsertSnippet(SnippetItem(id: "s1", accountID: f.account, name: "Thanks", shortcut: "ty",
                                              bodyHTML: "<p>Thanks</p>", variables: [], useCount: 0))
        #expect(await list.wait { $0.last?.map(\.id) == ["s1"] })

        try f.store.upsertSnippet(SnippetItem(id: "s2", accountID: nil, name: "Address", bodyHTML: "<p>Synthetic</p>",
                                              variables: [], useCount: 0))
        try f.store.upsertSnippet(SnippetItem(id: "s3", accountID: other, name: "Bye", bodyHTML: "<p>Bye</p>",
                                              variables: [], useCount: 0))
        #expect(await list.wait { $0.last?.map(\.id) == ["s2", "s1"] })
        #expect(try f.store.snippets(account: f.account) == list.values.last, "the same rows as the read")

        try f.store.deleteSnippet(id: "s1")
        #expect(await list.wait { $0.last?.map(\.id) == ["s2"] })
        list.stop()
    }
}
