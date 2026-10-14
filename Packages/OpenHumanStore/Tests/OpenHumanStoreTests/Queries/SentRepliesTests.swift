import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct SentRepliesTests {
    private func sent(_ id: String, minutes: Int, to: [String], reply: Bool = true, labels: [String] = ["SENT"],
                      names: [String: String] = [:]) -> MessageUpsert {
        var message = MessageUpsert.fixture(id, minutes: minutes, labels: labels, from: "me@example.com", fromName: "Me",
                                            to: to)
        message.headers?.to = to.map { EmailAddress(name: names[$0], email: $0) }
        if reply { message.headers?.inReplyTo = "earlier-\(id)@example.com" }
        return message
    }

    private static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func repliesAreCountedPerToRecipientSinceTheDate() throws {
        let f = try MutationFixture()
        try f.upsert([
            sent("r1", minutes: 10, to: ["dana@example.com", "sam@example.com"], names: ["dana@example.com": "Dana Ruiz"]),
            sent("r2", minutes: 20, to: ["Dana@Example.com"]),
            sent("r3", minutes: 30, to: ["dana@example.com", "dana@example.com"]),
            sent("old", minutes: -60 * 24 * 40, to: ["dana@example.com"]),
            sent("new", minutes: 40, to: ["lee@example.com"], reply: false),
            sent("draft", minutes: 50, to: ["dana@example.com"], labels: ["DRAFT"]),
            sent("bin", minutes: 55, to: ["dana@example.com"], labels: ["SENT", "TRASH"]),
            sent("self", minutes: 60, to: ["me@example.com"]),
        ])
        let since = Self.epoch.addingTimeInterval(-30 * 86_400)
        let replies = try f.store.sentReplies(account: f.account, since: since)
        #expect(replies.map(\.email) == ["dana@example.com", "sam@example.com"],
                "most replies first; a new message, a draft, trash, a note to self and older mail do not count")
        let dana = try #require(replies.first)
        #expect(dana.sentAt.count == 3, "a person twice on one message counts once")
        #expect(dana.sentAt.first == Self.epoch.addingTimeInterval(30 * 60), "newest first")
        #expect(dana.name == "Dana Ruiz")
        #expect(replies.last?.name == nil)
    }

    @Test func theScanIsBoundedAndAnEmptyAccountHasNone() throws {
        let f = try MutationFixture()
        #expect(try f.store.sentReplies(account: f.account, since: .distantPast).isEmpty)
        try f.upsert((0..<5).map { sent("m\($0)", minutes: $0, to: ["dana@example.com"]) })
        let bounded = try f.store.sentReplies(account: f.account, since: .distantPast, scanLimit: 2)
        #expect(bounded.first?.sentAt.count == 2, "only the newest sent messages are read")
        #expect(bounded.first?.sentAt.first == Self.epoch.addingTimeInterval(4 * 60))
    }
}
