import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct ObservationTests {
    @Test func aWriteThatChangesNothingVisibleDoesNotEmitAndArchiveEmitsOnce() async throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("a", thread: "ta", minutes: 1, labels: ["INBOX"]), .fixture("b", thread: "tb", minutes: 2, labels: ["INBOX"])])
        let window = Collector(f.store.observeThreadList(view: .system(f.account, .inbox), limit: 10))
        try #require(await window.waitForCount(1))
        #expect(window.values[0].items.count == 2)

        try f.upsert([.fixture("s", thread: "ts", labels: ["SENT"])])
        try f.store.insertDraft(account: f.account)
        try f.store.setSetting(.undoSendSeconds, 12, scope: .global)
        _ = try f.store.apply(.archive([try f.ref("ta")]), origin: .app)
        try f.upsert([.fixture("c", thread: "tc", minutes: 3, labels: ["INBOX"])])
        #expect(await window.wait { $0.last?.items.count == 2 && $0.last?.items.first?.ref.gmailThreadID.rawValue == "tc" })
        #expect(window.values.map(\.items.count) == [2, 1, 2])
        window.stop()
    }

    @Test func detailEmitsWhenABodyArrivesAndWhenADraftIsAdded() async throws {
        let f = try AggregationFixture()
        let result = try f.upsert([.fixture("m1", thread: "t1")])
        let tid = try firstTid(result)
        let detail = Collector(f.store.observeThreadDetail(tid))
        try #require(await detail.waitForCount(1))
        let mid = try #require(detail.values[0]?.messages.first?.id)
        let body = Collector(f.store.observeBody(mid))
        try #require(await body.waitForCount(1))
        #expect(body.values[0] == nil)
        try f.store.storeBodies([(GmailMessageID("m1"), .fixture(), [])], account: f.account)
        #expect(await body.wait { $0.last??.text == "Hi" })
        #expect(await detail.wait { $0.last??.messages.first?.bodyState == .stored })
        try f.store.insertDraft(account: f.account, id: "d1", tid: tid.rawValue, gmailThread: "t1")
        #expect(await detail.wait { $0.last??.drafts.map(\.id.rawValue) == ["d1"] })
        detail.stop(); body.stop()
    }

    @Test func detailOfAMissingThreadEmitsNilThenTheThreadWhenItAppears() async throws {
        let f = try AggregationFixture()
        let observation = Collector(f.store.observeThreadDetail(ThreadRowID(rawValue: 1)))
        try #require(await observation.waitForCount(1))
        #expect(observation.values[0] == .some(nil))
        try f.upsert([.fixture("m1", thread: "t1")])
        #expect(await observation.wait { $0.last??.messages.count == 1 })
        observation.stop()
    }

    @Test func countsAndLabelsFollowArchiveAndDrafts() async throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("a", thread: "ta", labels: ["INBOX", "UNREAD"]), .fixture("b", thread: "tb", labels: ["INBOX", "UNREAD"])])
        let counts = Collector(f.store.observeCounts(account: f.account))
        let labels = Collector(f.store.observeLabels(account: f.account))
        try #require(await counts.waitForCount(1))
        try #require(await labels.waitForCount(1))
        #expect(counts.values[0].inboxUnread == 2 && counts.values[0].draftsCount == 0)
        _ = try f.store.apply(.archive([try f.ref("ta")]), origin: .app)
        #expect(await counts.wait { $0.last?.inboxUnread == 1 })
        #expect(await labels.wait { $0.last?.first { $0.key == "INBOX" }?.unreadThreads == 1 })
        try f.store.insertDraft(account: f.account, review: "pending")
        #expect(await counts.wait { $0.last?.draftsCount == 1 && $0.last?.pendingReviewCount == 1 })
        counts.stop(); labels.stop()
    }

    @Test func splitsObservationFollowsRuleCountChanges() async throws {
        let f = try AggregationFixture()
        let splits = Collector(f.store.observeSplits(account: f.account))
        try #require(await splits.waitForCount(1))
        #expect(splits.values[0].first?.unreadThreads == 0)
        try f.upsert([.fixture("a", thread: "ta", labels: ["INBOX", "UNREAD", "IMPORTANT"])])
        #expect(await splits.wait { $0.last?.first?.unreadThreads == 1 })
        splits.stop()
    }

    @Test func draftObservationsEmitOnInsertEditStateChangeAndDelete() async throws {
        let f = try AggregationFixture()
        let all = Collector(f.store.observeDrafts(account: f.account, states: [.editing]))
        let review = Collector(f.store.observeReviewQueue(account: nil))
        let one = Collector(f.store.observeDraft(DraftID("d1")))
        try #require(await all.waitForCount(1))
        try #require(await review.waitForCount(1))
        try #require(await one.waitForCount(1))
        #expect(all.values[0].isEmpty && review.values[0].isEmpty && one.values[0] == nil)
        try f.store.insertDraft(account: f.account, id: "d1", review: "pending", origin: "agent")
        #expect(await all.wait { $0.last?.map(\.id.rawValue) == ["d1"] })
        #expect(await review.wait { $0.last?.map(\.id.rawValue) == ["d1"] })
        #expect(await one.wait { $0.last??.reviewState == .pending })
        try f.store.write { try $0.execute(sql: "UPDATE drafts SET subject = 'Changed', local_version = local_version + 1 WHERE draft_uuid = 'd1'") }
        #expect(await one.wait { $0.last??.content.subject == "Changed" && $0.last??.isDirty == true })
        try f.store.write { try $0.execute(sql: "UPDATE drafts SET state = 'sent', review_state = 'approved' WHERE draft_uuid = 'd1'") }
        #expect(await all.wait { $0.last?.isEmpty == true })
        #expect(await review.wait { $0.last?.isEmpty == true })
        try f.store.write { try $0.execute(sql: "DELETE FROM drafts WHERE draft_uuid = 'd1'") }
        #expect(await one.wait { $0.last == .some(nil) })
        all.stop(); review.stop(); one.stop()
    }

    @Test func failedOperationsAndSyncStatusObservationsEmitOnQueueChanges() async throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("a", thread: "ta"), .fixture("b", thread: "tb")])
        let failed = Collector(f.store.observeFailedOperations())
        let status = Collector(f.store.observeSyncStatus(account: f.account))
        try #require(await failed.waitForCount(1))
        try #require(await status.waitForCount(1))
        #expect(failed.values[0].isEmpty && status.values[0].pendingOperations == 0)
        let op = try f.op(["a"], remove: ["INBOX"], status: "pending")
        #expect(await status.wait { $0.last?.pendingOperations == 1 })
        try f.store.write { try $0.execute(sql: "UPDATE pending_operations SET status = 'failed' WHERE op_id = ?", arguments: [op]) }
        #expect(await failed.wait { $0.last?.map(\.id.rawValue) == [op] })
        #expect(await status.wait { $0.last?.failedOperations == 1 && $0.last?.pendingOperations == 0 })
        failed.stop(); status.stop()
    }

    @Test func leaseHeartbeatsDoNotEmitANewSyncStatus() async throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("a", thread: "ta")])
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try f.store.acquireLease(account: f.account, ownerID: "A", kind: "app", pid: ProcessInfo.processInfo.processIdentifier,
                                     host: ProcessIdentity.localHostName, now: t0, ttl: .seconds(45))
        let status = Collector(f.store.observeSyncStatus(account: f.account))
        try #require(await status.waitForCount(1))
        #expect(status.values[0].owner?.ownerID == "A")
        for beat in 1...5 {
            #expect(try f.store.renewLease(account: f.account, ownerID: "A", now: t0.addingTimeInterval(Double(beat) * 15),
                                           ttl: .seconds(45)))
        }
        _ = try f.op(["a"], remove: ["INBOX"], status: "pending")
        #expect(await status.wait { $0.last?.pendingOperations == 1 })
        #expect(status.values.count == 2, "five heartbeats produced no emission")
        #expect(try f.store.lease(account: f.account)?.heartbeatAt == t0.addingTimeInterval(75))
        status.stop()
    }

    @Test func syncStatusOfAnUnknownAccountFinishesTheStreamWithNotFound() async throws {
        let f = try AggregationFixture()
        let status = Collector(f.store.observeSyncStatus(account: AccountID(999)))
        await status.waitForEnd()
        #expect(status.values.isEmpty)
        #expect(status.error as? StoreError == .notFound("sync_state 999"))
    }

    @Test func remindersObservationEmitsOnSetCancelFireAndSubjectChange() async throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("a", thread: "ta", subject: "Alpha")])
        let tid = try f.tid("ta")
        let reminders = Collector(f.store.observeReminders(account: nil))
        try #require(await reminders.waitForCount(1))
        #expect(reminders.values[0].isEmpty)
        func set(_ id: String, due: Int64) throws {
            try f.store.write { db in
                try db.execute(sql: """
                    INSERT INTO reminders (reminder_id, tid, account_id, gmail_thread_id, set_at, due_at, condition, state)
                    VALUES (?, ?, ?, 'ta', 1, ?, 'always', 'active')
                    """, arguments: [id, tid, f.account.rawValue, due])
            }
        }
        try set("r1", due: 5000)
        #expect(await reminders.wait { $0.last?.map(\.subject) == ["Alpha"] })
        try f.store.write { try $0.execute(sql: "UPDATE threads SET subject = 'Renamed' WHERE tid = ?", arguments: [tid]) }
        #expect(await reminders.wait { $0.last?.first?.subject == "Renamed" })
        try f.store.write { try $0.execute(sql: "UPDATE reminders SET state = 'fired' WHERE reminder_id = 'r1'") }
        #expect(await reminders.wait { $0.last?.isEmpty == true })
        try set("r2", due: 6000)
        #expect(await reminders.wait { $0.last?.map(\.reminder.id) == ["r2"] })
        try f.store.write { try $0.execute(sql: "UPDATE reminders SET state = 'cancelled' WHERE reminder_id = 'r2'") }
        #expect(await reminders.wait { $0.last?.isEmpty == true })
        reminders.stop()
    }

    @Test func settingObservationStartsWithTheDefaultAndFollowsWrites() async throws {
        let f = try AggregationFixture()
        let setting = Collector(f.store.observeSetting(.undoSendSeconds, scope: .global))
        let scoped = Collector(f.store.observeSetting(.undoSendSeconds, scope: .account(f.account)))
        try #require(await setting.waitForCount(1))
        try #require(await scoped.waitForCount(1))
        #expect(setting.values == [10] && scoped.values == [10])
        try f.store.setSetting(.undoSendSeconds, 20, scope: .global)
        #expect(await setting.wait { $0.last == 20 })
        try f.store.setSetting(.undoSendSeconds, 30, scope: .account(f.account))
        #expect(await scoped.wait { $0.last == 30 })
        #expect(setting.values == [10, 20])
        setting.stop(); scoped.stop()
    }

    @Test func accountsObservationFollowsAddAndStatus() async throws {
        let f = try AggregationFixture()
        let accounts = Collector(f.store.observeAccounts())
        try #require(await accounts.waitForCount(1))
        let other = try f.store.addAccount(email: "o@example.com", displayName: nil, scopes: [])
        #expect(await accounts.wait { $0.last?.count == 2 })
        try f.store.setAccountStatus(other, .needsReauth)
        #expect(await accounts.wait { $0.last?.last?.status == .needsReauth })
        accounts.stop()
    }

    @Test func aBurstOfWritesEndsOnTheLatestStateWithoutMoreEmissionsThanWrites() async throws {
        let f = try AggregationFixture()
        let window = Collector(f.store.observeThreadList(view: .system(f.account, .inbox), limit: 100))
        try #require(await window.waitForCount(1))
        let writes = 40
        for i in 0..<writes { try f.upsert([.fixture("b\(i)", thread: "tb\(i)", minutes: i, labels: ["INBOX"])]) }
        #expect(await window.wait { $0.last?.totalCount == writes })
        #expect(window.values.count <= writes + 1)
        #expect(window.values.map(\.totalCount) == window.values.map(\.totalCount).sorted())
        window.stop()
    }

    @Test func cancellingStopsTheObservation() async throws {
        let f = try AggregationFixture()
        let id = f.store.writerID
        #expect(ObservationRegistry.active(id) == 0)
        let one = Collector(f.store.observeAccounts())
        let two = Collector(f.store.observeLabels(account: f.account))
        try #require(await one.waitForCount(1))
        try #require(await two.waitForCount(1))
        #expect(ObservationRegistry.active(id) == 2)
        one.stop()
        #expect(await waitUntil { ObservationRegistry.active(id) == 1 })
        two.stop()
        #expect(await waitUntil { ObservationRegistry.active(id) == 0 })
        _ = try f.store.addAccount(email: "late@example.com", displayName: nil, scopes: [])
        #expect(ObservationRegistry.active(id) == 0)
    }

    @Test func droppingAnUnreadStreamReleasesIt() async throws {
        let f = try AggregationFixture()
        let id = f.store.writerID
        do {
            var stream: AsyncThrowingStream<[AccountItem], Error>? = f.store.observeAccounts().values()
            #expect(ObservationRegistry.active(id) == 1)
            stream = nil
            _ = stream
        }
        #expect(await waitUntil { ObservationRegistry.active(id) == 0 })
    }

    @MainActor @Test func startCallbackDeliversTheCurrentValueFirstThenChangesAndStopsOnCancel() async throws {
        let f = try AggregationFixture()
        let id = f.store.writerID
        var seen: [Int] = []
        var errors = 0
        let token = f.store.observeAccounts().start(onError: { _ in errors += 1 }, onChange: { seen.append($0.count) })
        #expect(seen == [1])
        _ = try f.store.addAccount(email: "x@example.com", displayName: nil, scopes: [])
        #expect(await waitUntil { seen.last == 2 })
        #expect(seen == [1, 2] && errors == 0)
        token.cancel()
        #expect(await waitUntil { ObservationRegistry.active(id) == 0 })
        _ = try f.store.addAccount(email: "y@example.com", displayName: nil, scopes: [])
        try await Task.sleep(for: .milliseconds(50))
        #expect(seen == [1, 2])
    }

    @MainActor @Test func startReportsAnErrorFromTheImmediateRead() throws {
        let f = try AggregationFixture()
        var errors: [StoreError] = []
        var values = 0
        let token = f.store.observeSyncStatus(account: AccountID(999))
            .start(onError: { errors.append(($0 as? StoreError) ?? .integrity("?")) }, onChange: { _ in values += 1 })
        #expect(errors == [.notFound("sync_state 999")] && values == 0)
        token.cancel()
    }
}
