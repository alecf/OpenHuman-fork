import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct OwnSentCopyUnreadTests {
    private func conversation(_ h: WriteHarness, _ thread: String) throws -> ThreadListItem {
        try #require(try h.store.thread(try h.ref(thread)))
    }

    @Test func aSentReplyLeavesItsReadConversationRead() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let thread = h.threads[0]
        await h.gmail.simulateWebRead(threadID: thread)
        try await h.syncer.sync(reason: "poll")
        #expect(try !conversation(h, thread).isUnread)
        let inboxUnread = try h.store.label(account: h.account, key: "INBOX")?.unreadThreads

        let original = try #require(await h.gmail.messageIDs(inThread: thread).first)
        let originalID = "<\(original)@fake.openhuman.invalid>"
        let id = try h.newDraft(subject: "Re: Seeded thread 0", headers: ["In-Reply-To": originalID, "References": originalID],
                                mode: .reply, replyTo: GmailMessageID(original))
        let receipt = try h.store.send(id, undoWindow: .zero, origin: .app)
        h.advancePast(receipt)
        await drainer.drainOnce()
        let sent = try #require(try await h.sentOnGmail().first)
        var item = try conversation(h, thread)
        #expect(item.messageCount == 2 && !item.isUnread && item.unreadCount == 0)

        await h.gmail.modifyLabels(messageID: sent, add: ["UNREAD", "INBOX"])
        try await h.syncer.sync(reason: "poll")
        item = try conversation(h, thread)
        #expect(!item.isUnread && item.unreadCount == 0)
        #expect(try h.store.label(account: h.account, key: "INBOX")?.unreadThreads == inboxUnread)

        await h.gmail.deliver(from: "Me <me@example.com>", subject: "Re: Seeded thread 0", labels: ["SENT", "UNREAD"],
                              threadID: thread)
        try await h.syncer.sync(reason: "poll")
        item = try conversation(h, thread)
        #expect(item.messageCount == 3 && !item.isUnread && item.unreadCount == 0)

        await h.gmail.deliver(subject: "Re: Seeded thread 0", labels: ["INBOX", "UNREAD"], threadID: thread)
        try await h.syncer.sync(reason: "poll")
        item = try conversation(h, thread)
        #expect(item.isUnread && item.unreadCount == 1)
    }
}
