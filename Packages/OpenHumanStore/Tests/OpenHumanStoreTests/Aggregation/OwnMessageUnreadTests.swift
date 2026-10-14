import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct OwnMessageUnreadTests {
    private struct Seen: Equatable {
        var unreadCount: Int
        var inboxRowUnread: Bool?
        var inUnreadView: Bool
        var inboxUnreadThreads: Int
    }

    private func seen(_ f: AggregationFixture, _ thread: String) throws -> Seen {
        let t = try f.tid(thread)
        let row: Bool? = try f.store.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT tl.unread FROM thread_labels tl JOIN labels l USING (label_rid) WHERE tl.tid = ? AND l.key = 'INBOX'
                """, arguments: [t])
        }
        return Seen(unreadCount: try f.threadRow(thread)["unread_count"], inboxRowUnread: row,
                    inUnreadView: try f.keys(thread).contains("UNREAD"),
                    inboxUnreadThreads: try f.store.label(account: f.account, key: "INBOX")?.unreadThreads ?? -1)
    }

    private static let read = Seen(unreadCount: 0, inboxRowUnread: false, inUnreadView: false, inboxUnreadThreads: 0)

    @Test func anOwnSentReplyInAReadConversationKeepsItRead() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "t", minutes: 0, labels: ["INBOX"])])
        #expect(try seen(f, "t") == Self.read)
        try f.upsert([.fixture("s1", thread: "t", minutes: 5, labels: ["SENT"], from: "me@example.com", fromName: "Me")])
        #expect(try seen(f, "t") == Self.read)
        try f.upsert([.fixture("s1", thread: "t", minutes: 5, labels: ["SENT", "INBOX", "UNREAD"], from: "me@example.com",
                               fromName: "Me", history: 2)])
        #expect(try seen(f, "t") == Self.read)
        #expect(try f.sortKeys("t")["INBOX"] == baseMillis + 5 * 60_000)
    }

    @Test func sentMailFromAnotherClientDoesNotMarkItUnread() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "t", minutes: 0, labels: ["INBOX"])])
        try f.upsert([.fixture("w1", thread: "t", minutes: 3, labels: ["SENT", "UNREAD"], from: "me@example.com")])
        #expect(try seen(f, "t") == Self.read)
        try f.upsert([.fixture("w2", thread: "t", minutes: 4, labels: ["SENT", "INBOX", "UNREAD"], from: "new-alias@example.org")])
        #expect(try seen(f, "t") == Self.read)
        try f.upsert([.fixture("w3", thread: "t", minutes: 6, labels: ["INBOX", "UNREAD"], from: "ME@example.com")])
        #expect(try seen(f, "t") == Self.read)
    }

    @Test func aMessageFromSomeoneElseStillMarksItUnread() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "t", minutes: 0, labels: ["INBOX"]),
                      .fixture("s1", thread: "t", minutes: 5, labels: ["SENT", "INBOX", "UNREAD"], from: "me@example.com")])
        #expect(try seen(f, "t") == Self.read)
        try f.upsert([.fixture("m2", thread: "t", minutes: 9, labels: ["INBOX", "UNREAD"], from: "bob@example.com",
                               fromName: "Bob Jones")])
        #expect(try seen(f, "t") == Seen(unreadCount: 1, inboxRowUnread: true, inUnreadView: true, inboxUnreadThreads: 1))
        #expect(try f.sortKeys("t")["INBOX"] == baseMillis + 9 * 60_000)
    }

    @Test func aliasSendersCountAsOwn() throws {
        let f = try AggregationFixture()
        try f.store.updateSendAs(account: f.account, identities: [
            SendAsIdentity(email: "me@example.com", isDefault: true, isPrimary: true),
            SendAsIdentity(email: "Support@Example.org", isDefault: false, isPrimary: false),
        ])
        try f.upsert([.fixture("m1", thread: "t", minutes: 0, labels: ["INBOX"]),
                      .fixture("a1", thread: "t", minutes: 2, labels: ["INBOX", "UNREAD"], from: "support@example.org",
                               fromName: "Support")])
        #expect(try seen(f, "t") == Self.read)

        try f.upsert([.fixture("b1", thread: "u", minutes: 0, labels: ["INBOX", "UNREAD"], from: "sales@example.org")])
        #expect(try seen(f, "u").unreadCount == 1)
        try f.store.updateSendAs(account: f.account, identities: [
            SendAsIdentity(email: "me@example.com", isDefault: true, isPrimary: true),
            SendAsIdentity(email: "support@example.org", isDefault: false, isPrimary: false),
            SendAsIdentity(email: "sales@example.org", isDefault: false, isPrimary: false),
        ])
        #expect(try seen(f, "u") == Self.read)
    }
}
