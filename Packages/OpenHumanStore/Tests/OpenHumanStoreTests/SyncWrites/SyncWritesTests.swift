import Foundation
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct SyncWritesTests {
    private func inbox(_ store: MailStore, _ account: AccountID) throws -> [String] {
        try store.threadPage(view: .system(account, .inbox), after: nil, limit: 100).items.map(\.ref.gmailThreadID.rawValue)
    }

    @Test func deleteTombstonesAndRemovesEmptyThreads() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.upsertMessages([.fixture("m1", thread: "t1", history: 10), .fixture("m2", thread: "t1", minutes: 1, history: 11),
                                      .fixture("m3", thread: "t2", minutes: 2, history: 12)], account: account, generation: 1)
        let r = try store.deleteMessages([GmailMessageID("m1"), GmailMessageID("m3"), GmailMessageID("unknown")],
                                         account: account, historyID: HistoryID(20))
        #expect(r.updated == 2)
        #expect(try inbox(store, account) == ["t1"])
        let t1 = try #require(try store.thread(account: account, gmailThreadID: GmailThreadID("t1")))
        #expect(try store.threadDetail(t1.rowID)?.messages.map(\.gmailMessageID.rawValue) == ["m2"])
        let stale = try store.upsertMessages([.fixture("m1", thread: "t1", history: 15)], account: account, generation: 1)
        #expect(stale.skippedTombstoned == 1 && stale.inserted == 0)
        let fresh = try store.upsertMessages([.fixture("m1", thread: "t1", history: 21)], account: account, generation: 1)
        #expect(fresh.inserted == 1)
    }

    @Test func labelDeltasApplyAddRemoveFullSetAndHonorTheHistoryGuard() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.upsertMessages([.fixture("m1", thread: "t1", labels: ["INBOX", "UNREAD"], history: 10)],
                                     account: account, generation: 1)
        var r = try store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("m1"), historyID: HistoryID(9),
                                                       added: [], removed: [GmailLabelID("INBOX")])], account: account)
        #expect(try r.skippedStale == 1 && inbox(store, account) == ["t1"])
        r = try store.applyLabelDeltas([
            LabelDelta(gmailMessageID: GmailMessageID("m1"), historyID: HistoryID(11), added: [], removed: [GmailLabelID("INBOX")]),
            LabelDelta(gmailMessageID: GmailMessageID("m1"), historyID: HistoryID(12), added: [GmailLabelID("STARRED")],
                       removed: [GmailLabelID("UNREAD")]),
            LabelDelta(gmailMessageID: GmailMessageID("missing"), historyID: HistoryID(12), added: [], removed: []),
        ], account: account)
        #expect(r.updated == 2 && r.touchedThreads.count == 1)
        #expect(try inbox(store, account).isEmpty)
        let m = try #require(try store.message(account: account, gmailMessageID: GmailMessageID("m1")))
        #expect(Set(m.labelIDs.map(\.rawValue)) == ["STARRED"] && !m.isUnread && m.isStarred)
        r = try store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID("m1"), historyID: HistoryID(13),
                                                   added: [], removed: [],
                                                   fullSetIfKnown: [GmailLabelID("INBOX"), GmailLabelID("Label_9")])],
                                       account: account)
        #expect(try r.unknownLabelIDs == [GmailLabelID("Label_9")] && inbox(store, account) == ["t1"])
    }

    @Test func syncStateUpdatesAndFailureCounting() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        #expect(try store.syncStatus(account: account).phase == .new)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try store.updateSyncState(account: account) {
            $0.phase = .incremental
            $0.historyID = HistoryID(42)
            $0.bootstrapHistoryID = HistoryID(40)
            $0.lastSuccessAt = now
        }
        try store.updateSyncState(account: account) {
            $0.incrementFailures = true
            $0.lastErrorCode = "server_503"
            $0.lastErrorMessage = "server_503"
        }
        try store.updateSyncState(account: account) { $0.incrementFailures = true }
        var s = try store.syncStatus(account: account)
        #expect(s.phase == .incremental && s.historyID == HistoryID(42) && s.lastSuccessAt == now)
        #expect(s.consecutiveFailures == 2 && s.lastError == "server_503" && s.generation == 1)
        try store.updateSyncState(account: account) { $0.consecutiveFailures = 0; $0.clearLastError = true }
        s = try store.syncStatus(account: account)
        #expect(s.consecutiveFailures == 0 && s.lastError == nil)
        #expect(throws: StoreError.conflict("sync_state")) {
            try store.updateSyncState(account: account) { $0.incrementFailures = true; $0.consecutiveFailures = 3 }
        }
        #expect(throws: StoreError.notFound("sync_state 999")) {
            try store.updateSyncState(account: AccountID(999)) { $0.phase = .new }
        }
    }

    @Test func resyncGenerationAndSweep() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.upsertMessages([.fixture("old", thread: "t1", minutes: 0), .fixture("kept", thread: "t2", minutes: 10),
                                      .fixture("gone", thread: "t3", minutes: 20)], account: account, generation: 1)
        let gen = try store.beginFullResync(account: account)
        #expect(try gen == 2 && store.syncStatus(account: account).generation == 2)
        _ = try store.upsertMessages([.fixture("kept", thread: "t2", minutes: 10)], account: account, generation: gen)
        let horizon = Date(timeIntervalSince1970: 1_790_000_000 + 5 * 60)
        #expect(try store.sweepGeneration(account: account, olderThan: gen, newerThan: horizon) == 1)
        #expect(Set(try inbox(store, account)) == ["t1", "t2"])
        #expect(try store.sweepGeneration(account: account, olderThan: gen, newerThan: nil) == 1)
        #expect(try inbox(store, account) == ["t2"])
    }

    @Test func syncLogRingBufferNewestFirst() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        for i in 0..<1003 {
            try store.appendSyncLog(SyncLogEntry(accountID: account, startedAt: Date(timeIntervalSince1970: Double(1_000 + i)),
                                                 finishedAt: Date(timeIntervalSince1970: Double(1_001 + i)),
                                                 kind: "incremental", outcome: "ok", quotaUnits: i, requests: 1))
        }
        let log = try store.syncLog(account: account, limit: 2000)
        #expect(log.count == 1000)
        #expect(log.first?.quotaUnits == 1002 && log.last?.quotaUnits == 3)
        #expect(try store.syncLog(account: account, limit: 1).first?.kind == "incremental")
    }

    @Test func newMessageWithHeadersAndBodyIsStored() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.upsertMessages([.fixture("m1", body: .fixture())], account: account, generation: 1)
        let m = try #require(try store.message(account: account, gmailMessageID: GmailMessageID("m1")))
        #expect(m.bodyState == .stored && m.subject == "Hello")
        #expect(try store.body(m.id)?.html == "<p>Hi</p>")
    }

    @Test func pruneTombstones() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.deleteMessages([GmailMessageID("x")], account: account, historyID: HistoryID(5))
        try store.pruneTombstones(account: account, olderThan: Date().addingTimeInterval(60))
        #expect(try store.upsertMessages([.fixture("x", history: 1)], account: account, generation: 1).inserted == 1)
    }
}
