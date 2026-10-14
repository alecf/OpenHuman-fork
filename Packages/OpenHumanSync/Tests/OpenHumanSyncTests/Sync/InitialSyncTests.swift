import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanSync

@Suite struct InitialSyncTests {
    @Test func firstSyncStoresTheNewestFiftyInboxThreads() async throws {
        let h = try SyncHarness()
        await h.gmail.seedInbox(count: 60)
        await h.gmail.deliver(subject: "Archived", labels: ["CATEGORY_UPDATES"])
        await h.gmail.deliver(subject: "Junk", labels: ["SPAM"])
        await h.gmail.latency(.getThread, .milliseconds(100))
        let bootstrap = await h.gmail.currentHistoryID
        await h.gmail.resetAccounting()

        let report = try await h.syncer.sync(reason: "launch")

        for (method, count) in [(GmailMethod.getProfile, 1), (.listLabels, 1), (.listSendAs, 1), (.listThreads, 1),
                                (.getThread, 50), (.getMessage, 10), (.listHistory, 0)] {
            #expect(await h.gmail.callCount(method) == count, "\(method)")
        }
        let units = await h.gmail.unitsUsed
        #expect(units == 2_213 && units <= 2_300)
        let peak = await h.gmail.maxConcurrentCalls
        #expect(peak >= 2 && peak <= 8)
        let expected = Array(try await h.serverInbox().prefix(50))
        #expect(try h.inbox() == expected)
        let status = try h.status()
        #expect(status.phase == .inboxReady && status.historyID == bootstrap && status.consecutiveFailures == 0)
        #expect(report.kind == "inbox" && report.added == 50 && report.units == 2_213)
        for (index, thread) in expected.prefix(11).enumerated() {
            let message = try #require(try h.thread(thread)?.messages.last)
            #expect(message.bodyState == (index < 10 ? .stored : .metadataOnly), "thread \(index)")
        }
        let log = try h.store.syncLog(account: h.account, limit: 10)
        #expect(log.count == 1 && log.first?.kind == "inbox" && log.first?.outcome == "ok")
        #expect(log.first?.quotaUnits == 2_213 && log.first?.requests == 64 && log.first?.added == 50)
    }

    @Test func headersLabelsAndSendAsAreStored() async throws {
        let h = try SyncHarness()
        let label = await h.gmail.addUserLabel("Clients")
        let (m1, t1) = await h.gmail.deliver(from: "Ann Example <ann@example.com>", subject: "Plans",
                                             labels: ["INBOX", "UNREAD", label])
        await h.gmail.setSendAs([GmailSendAs(sendAsEmail: "ME@example.com", signature: "<div>Me</div>", isPrimary: true,
                                             isDefault: true),
                                 GmailSendAs(sendAsEmail: "alias@example.com", displayName: "Alias",
                                             verificationStatus: "pending")])
        try await h.syncer.sync(reason: "launch")
        let message = try #require(try h.message(m1))
        #expect(message.subject == "Plans" && message.from?.email == "ann@example.com" && message.isUnread)
        #expect(Set(message.labelIDs.map(\.rawValue)) == ["INBOX", "UNREAD", label])
        #expect(try h.thread(t1)?.labels.map(\.name) == ["Clients"])
        #expect(try h.store.label(account: h.account, key: label)?.kind == .user)
        let sendAs = try #require(try h.store.accounts().first?.sendAs)
        #expect(sendAs.map(\.email) == ["me@example.com", "alias@example.com"])
        #expect(sendAs.map(\.signatureHTML) == ["<div>Me</div>", nil])
        #expect(sendAs.map(\.verificationStatus) == [nil, "pending"])
    }

    @Test func sendAsForbiddenFallsBackToTheProfileAddress() async throws {
        let h = try SyncHarness()
        await h.gmail.deliver()
        await h.gmail.failNext(.listSendAs, with: .forbidden(reason: "insufficientPermissions", message: "scope"))
        try await h.syncer.sync(reason: "launch")
        #expect(try h.store.accounts().first?.sendAs.map(\.email) == ["me@example.com"])
        #expect(try h.status().phase == .inboxReady)
    }

    @Test func aFailedThreadFetchIsRetriedNextRunAndStoredThreadsAreSkipped() async throws {
        let h = try SyncHarness()
        await h.gmail.seedInbox(count: 5)
        await h.gmail.failNext(.getThread, with: .server(status: 503, message: nil))
        await #expect(throws: GmailError.server(status: 503, message: nil)) { try await h.syncer.sync(reason: "launch") }
        var status = try h.status()
        #expect(status.phase == .inboxReady && status.historyID == nil && status.consecutiveFailures == 1)
        #expect(try h.inbox().count == 4)
        await h.gmail.resetAccounting()
        try await h.syncer.sync(reason: "retry")
        #expect(await h.gmail.callCount(.getThread) == 1)
        status = try h.status()
        #expect(try status.phase == .inboxReady && status.consecutiveFailures == 0 && h.inbox().count == 5)
    }

    @Test func changesDuringTheInitialListingArriveWithTheFirstIncremental() async throws {
        let h = try SyncHarness()
        let threads = await h.gmail.seedInbox(count: 3)
        let archived = threads[2]
        let newThread = Box<String>()
        await h.gmail.afterNext(.listThreads) { g in newThread.value = g.deliver(subject: "Arrived mid-listing").threadID }
        await h.gmail.afterNext(.getThread) { g in
            for t in g.messageIDs(inThread: archived) where g.labelIDs(ofMessage: t)?.contains("INBOX") == true {
                g.modifyLabels(messageID: t, remove: ["INBOX"])
            }
        }
        try await h.syncer.sync(reason: "launch")
        let arrived = try #require(newThread.value)
        #expect(try !h.inbox().contains(arrived))
        try await h.syncer.sync(reason: "poll")
        let inbox = try h.inbox()
        #expect(inbox == (try await h.serverInbox()))
        #expect(inbox.contains(arrived) && !inbox.contains(archived))
    }

    @Test func emptyMailbox() async throws {
        let h = try SyncHarness()
        let report = try await h.syncer.sync(reason: "launch")
        #expect(try report.added == 0 && h.inbox().isEmpty && h.status().phase == .inboxReady)
    }
}

final class Box<T: Sendable>: Sendable {
    private let storage = Mutex<T?>(nil)
    var value: T? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
