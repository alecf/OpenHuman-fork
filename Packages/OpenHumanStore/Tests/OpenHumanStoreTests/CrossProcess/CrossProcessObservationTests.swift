import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite(.serialized) struct CrossProcessObservationTests {
    private func appStore(threads: Int) throws -> (MailStore, URL, AccountID) {
        let (store, dir) = try openTemp(kind: .app, observe: true)
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        try store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: account, removeMissing: false)
        let messages = (0..<threads).map { MessageUpsert.fixture("m\($0)", thread: "t\($0)", minutes: $0, labels: ["INBOX"]) }
        _ = try store.upsertMessages(messages, account: account, generation: 1)
        return (store, dir, account)
    }

    @Test func anArchiveWrittenByTheHelperProcessEmitsInTheAppsThreadList() async throws {
        let (store, dir, account) = try appStore(threads: 3)
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = Collector(store.observeThreadList(view: .system(account, .inbox), limit: 50))
        try #require(await list.waitForCount(1))
        #expect(list.values[0].items.count == 3)
        let ref = try #require(try store.thread(account: account, gmailThreadID: GmailThreadID("t1")))
        let helper = try HelperProcess(["write-archive", dir.path, String(ref.rowID.rawValue)])
        #expect(helper.waitFor("done"), Comment(rawValue: helper.stderrText))
        #expect(helper.finish() == 0)
        #expect(await list.wait { $0.last?.items.map(\.ref.gmailThreadID.rawValue).sorted() == ["t0", "t2"] })
        let counts = Collector(store.observeCounts(account: account))
        #expect(await counts.wait { $0.last?.inboxUnread == 0 })
        list.stop(); counts.stop()
        try store.close()
    }

    @Test func aWriteFromASecondStoreOnTheSameFileEmitsInTheFirst() async throws {
        let (store, dir, account) = try appStore(threads: 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (other, _) = try openTemp(kind: .cli, dir: dir)
        let list = Collector(store.observeThreadList(view: .system(account, .inbox), limit: 50))
        let drafts = Collector(store.observeDrafts(account: account, states: []))
        try #require(await list.waitForCount(1))
        try #require(await drafts.waitForCount(1))
        _ = try other.upsertMessages([.fixture("new", thread: "tnew", minutes: 100, labels: ["INBOX"])], account: account, generation: 1)
        #expect(await list.wait { $0.last?.items.first?.ref.gmailThreadID.rawValue == "tnew" && $0.last?.totalCount == 2 })
        try other.insertDraft(account: account, id: "from-cli")
        #expect(await drafts.wait { $0.last?.map(\.id.rawValue) == ["from-cli"] })
        list.stop(); drafts.stop()
        try other.close()
        try store.close()
    }

    @Test func aStoreWithoutExternalMonitoringDoesNotSeeAnotherStoresWrite() async throws {
        let (store, dir) = try openTemp(kind: .test, observe: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let (other, _) = try openTemp(kind: .cli, dir: dir)
        let accounts = Collector(store.observeAccounts())
        try #require(await accounts.waitForCount(1))
        _ = try other.addAccount(email: "second@example.com", displayName: nil, scopes: [])
        #expect(try store.accounts().count == 2)
        _ = try store.addAccount(email: "third@example.com", displayName: nil, scopes: [])
        #expect(await accounts.wait { $0.last?.count == 3 })
        _ = account
        accounts.stop()
        try other.close()
        try store.close()
    }

    @Test func thePollFallbackAloneWakesTheObserverOfAnotherProcessWrite() async throws {
        setenv("OPENHUMAN_STORE_POLL_ONLY", "1", 1)
        let (store, dir) = try openTemp(kind: .app, observe: true)
        unsetenv("OPENHUMAN_STORE_POLL_ONLY")
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        try store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: account, removeMissing: false)
        _ = try store.upsertMessages([.fixture("m1", thread: "t1", labels: ["INBOX"])], account: account, generation: 1)
        let list = Collector(store.observeThreadList(view: .system(account, .inbox), limit: 50))
        try #require(await list.waitForCount(1))
        let tid = try store.threadID(account, "t1")
        let helper = try HelperProcess(["write-archive", dir.path, String(tid)])
        #expect(helper.waitFor("done"), Comment(rawValue: helper.stderrText))
        #expect(helper.finish() == 0)
        #expect(await list.wait { $0.last?.items.isEmpty == true })
        list.stop()
        try store.close()
    }
}
