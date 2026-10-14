import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct BodyFetcherTests {
    private func harness() throws -> SyncHarness {
        try SyncHarness(settings: SyncSettings(prefetchFullBodies: 0))
    }

    @Test func openedThreadGetsItsBodiesInOneThreadFetch() async throws {
        let h = try harness()
        let (first, thread) = await h.gmail.deliver(subject: "Hi", body: "First text", html: "<p>First</p>")
        let (second, _) = await h.gmail.deliver(subject: "Re: Hi", body: "Second text", threadID: thread)
        try await h.syncer.sync(reason: "launch")
        #expect(try h.message(first)?.bodyState == .metadataOnly)
        await h.gmail.resetAccounting()

        let fetcher = BodyFetcher(account: h.account, store: h.store, api: h.gmail)
        let ref = try #require(try h.store.thread(account: h.account, gmailThreadID: GmailThreadID(thread)))
        #expect(try await fetcher.ensureBodies(thread: ref.rowID) == 2)
        #expect(await h.gmail.callLog == [.getThread])
        let m1 = try #require(try h.message(first)), m2 = try #require(try h.message(second))
        #expect(m1.bodyState == .stored && m2.bodyState == .stored)
        #expect(try h.store.body(m1.id)?.html == "<p>First</p>" && (try h.store.body(m2.id))?.text == "Second text")
        #expect(try await fetcher.ensureBodies(thread: ref.rowID) == 0)
        #expect(await h.gmail.callLog == [.getThread])
    }

    @Test func singleMessageUsesMessagesGetAndAGoneMessageIsRemoved() async throws {
        let h = try harness()
        let (only, thread) = await h.gmail.deliver(subject: "Solo", body: "Solo body")
        let (doomed, doomedThread) = await h.gmail.deliver(subject: "Doomed")
        try await h.syncer.sync(reason: "launch")
        await h.gmail.resetAccounting()
        let fetcher = BodyFetcher(account: h.account, store: h.store, api: h.gmail)
        let ref = try #require(try h.store.thread(account: h.account, gmailThreadID: GmailThreadID(thread)))
        #expect(try await fetcher.ensureBodies(thread: ref.rowID) == 1)
        #expect(try await h.gmail.callLog == [.getMessage] && h.message(only)?.bodyState == .stored)

        await h.gmail.deleteMessagePermanently(doomed)
        #expect(try await fetcher.ensureBody(GmailMessageID(doomed)) == false)
        #expect(try h.message(doomed) == nil && (try h.thread(doomedThread)) == nil)
    }
}
