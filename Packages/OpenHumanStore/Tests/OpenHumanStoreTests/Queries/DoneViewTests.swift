import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct DoneViewTests {
    @Test func doneListsArchivedConversationsOnly() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.upsertMessages([
            .fixture("m1", thread: "inbox", minutes: 0, labels: ["INBOX"]),
            .fixture("m2", thread: "archived", minutes: 1, labels: []),
            .fixture("m3", thread: "trashed", minutes: 2, labels: ["TRASH"]),
            .fixture("d1", thread: "draftonly", minutes: 3, labels: ["DRAFT"], from: "me@example.com", fromName: nil),
            .fixture("s1", thread: "sent", minutes: 4, labels: ["SENT"], from: "me@example.com", fromName: nil,
                     to: ["bob@example.com"]),
        ], account: account, generation: 1)
        let page = try store.threadPage(view: .system(account, .done), after: nil, limit: 10)
        #expect(page.items.map(\.ref.gmailThreadID.rawValue) == ["sent", "archived"])
        let window = try store.read { db in try MailStore.window(view: .system(account, .done), limit: 10, in: db) }
        #expect(window.totalCount == 2 && !window.hasMore)
        let all = try store.threadPage(view: .system(account, .allMail), after: nil, limit: 10)
        #expect(all.items.contains { $0.ref.gmailThreadID.rawValue == "inbox" })
    }

    @Test func markingDoneMovesAConversationIntoDoneAndBackToInboxTakesItOut() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.upsertMessages([.fixture("m1", thread: "t1", labels: ["INBOX"])], account: account, generation: 1)
        #expect(try store.threadPage(view: .system(account, .done), after: nil, limit: 10).items.isEmpty)
        _ = try store.upsertMessages([.fixture("m1", thread: "t1", labels: [], history: 2)], account: account, generation: 1)
        #expect(try store.threadPage(view: .system(account, .done), after: nil, limit: 10).items.count == 1)
        _ = try store.upsertMessages([.fixture("m1", thread: "t1", labels: ["INBOX"], history: 3)], account: account,
                                     generation: 1)
        #expect(try store.threadPage(view: .system(account, .done), after: nil, limit: 10).items.isEmpty)
    }

    @Test func pagingTheDoneViewKeepsItsFilter() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        var messages: [MessageUpsert] = []
        for i in 0..<5 {
            messages.append(.fixture("a\(i)", thread: "a\(i)", minutes: i * 2, labels: []))
            messages.append(.fixture("i\(i)", thread: "i\(i)", minutes: i * 2 + 1, labels: ["INBOX"]))
        }
        _ = try store.upsertMessages(messages, account: account, generation: 1)
        let first = try store.threadPage(view: .system(account, .done), after: nil, limit: 3)
        let next = try #require(first.nextCursor)
        let second = try store.threadPage(view: .system(account, .done), after: next, limit: 3)
        let ids = (first.items + second.items).map(\.ref.gmailThreadID.rawValue)
        #expect(ids == ["a4", "a3", "a2", "a1", "a0"])
    }
}
