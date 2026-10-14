import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFakes

@Test func recentThreadsInvolvingAPersonAreNewestFirstAndBounded() async throws {
    let store = makeStore()
    var found: (email: String, rows: [ThreadRow])?
    for contact in try await store.contactSuggestions(work, prefix: "", limit: 10) {
        let rows = try await store.recentThreads(involving: contact.email, account: work, limit: 5)
        if !rows.isEmpty {
            found = (contact.email, rows)
            break
        }
    }
    let (email, rows) = try #require(found, "the rich corpus has people with conversations")
    #expect(rows.count <= 5)
    #expect(rows.allSatisfy { $0.id.account == work })
    #expect(rows.map(\.lastMessageAt) == rows.map(\.lastMessageAt).sorted(by: >))
    let one = try await store.recentThreads(involving: email.uppercased(), account: work, limit: 1)
    #expect(one.map(\.id) == Array(rows.prefix(1)).map(\.id), "addresses compare case-insensitively")
    #expect(try await store.recentThreads(involving: "nobody@example.org", account: work, limit: 5).isEmpty)
    #expect(try await store.recentThreads(involving: email, account: work, limit: 0).isEmpty)
}
