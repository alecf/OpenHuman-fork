import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct BackfillTests {
    @Test(.timeLimit(.minutes(10))) func aFiveThousandThreadMailboxBackfillsNewestFirstAndResumesAfterAQuit() async throws {
        let clock = InstantClock(now: testNow)
        var settings = backfillSettings()
        settings.bodyDownload = BodyDownloadPolicy(enabled: false)
        let h = try SyncHarness(settings: settings, clock: clock, recording: true)
        let recorder = try #require(h.recorder)
        let seeded = await h.gmail.seedMailbox(count: 5_000, end: testNow.addingTimeInterval(-3_600))
        let serverInbox = try await serverThreads(h.gmail, label: "INBOX")
        let serverMessages = try await serverMessageIDs(h.gmail)
        #expect(serverInbox.count == 4_000 && serverMessages.count == seeded.messages)

        try await h.syncer.sync(reason: "launch")
        #expect(try h.fullInbox().count == 50 && h.status().phase == .inboxReady)

        let progress = ProgressLog(h.syncer.observeProgress())
        defer { progress.stop() }
        recorder.setHook { call, n in
            if call.method == .listMessages && n == 3 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        #expect(await h.syncer.runBackfill() == .cancelled)
        var status = try h.status()
        #expect(status.phase == .backfilling && !status.backfillComplete)
        let cursor = try #require(status.backfillOldest)
        #expect(cursor < AccountSyncer.walkTop)
        #expect(Set(try h.fullInbox().map(\.ref.gmailThreadID.rawValue)) == Set(serverInbox))
        let firstRun = recorder.calls
        recorder.setHook(nil)
        recorder.reset()

        let relaunched = h.relaunched(api: recorder, settings: settings)
        let started = clock.now
        #expect(await relaunched.runBackfill() == .complete)
        let elapsed = clock.now.timeIntervalSince(started)
        let secondRun = recorder.calls
        #expect(!secondRun.contains { $0.method == .listThreads })
        #expect(secondRun.first { $0.method == .listMessages }?.query == AccountSyncer.beforeQuery(cursor, inclusive: true))
        status = try h.status()
        #expect(status.phase == .incremental && status.backfillComplete && status.consecutiveFailures == 0)

        #expect(try h.localMessages(among: serverMessages) == serverMessages)
        let inbox = try h.fullInbox()
        #expect(Set(inbox.map(\.ref.gmailThreadID.rawValue)) == Set(serverInbox))
        #expect(try h.allMailCount() == 5_000)
        #expect(zip(inbox, inbox.dropFirst()).allSatisfy { $0.sortAt >= $1.sortAt })
        for item in inbox.prefix(200) where seeded.repliedByMe.contains(item.ref.gmailThreadID.rawValue) {
            let detail = try #require(try h.store.threadDetail(item.id))
            #expect(item.lastMessageAt == detail.messages.map(\.date).max())
            #expect(detail.messages.last?.isFromMe == true)
        }

        let fetched = (firstRun + secondRun).filter { $0.method == .getThread }.reduce(0) { $0 + $1.items }
        #expect(fetched >= 5_000 && fetched <= 5_000 + settings.fetchChunk)
        #expect((firstRun + secondRun).filter { $0.method == .getThread }.allSatisfy { $0.items <= settings.fetchChunk })
        #expect(secondRun.filter { $0.method == .getMessage }.allSatisfy { $0.items <= settings.bodyChunk })
        #expect(firstRun.filter { $0.method == .listThreads }.first?.priority == .interactive)
        #expect(firstRun.filter { $0.method == .listThreads }.dropFirst().allSatisfy { $0.priority == .sync })
        #expect(secondRun.filter { [.listMessages, .getThread, .getMessage].contains($0.method) }
            .allSatisfy { $0.priority == .backfill })
        let units = await relaunched.pacer.units
        let rate = Double(settings.backfillUnitsPerMinute) / 60
        #expect(units > 5_000)
        #expect(Double(units) <= Double(settings.backfillUnitsPerMinute) / 4 + rate * elapsed + 1)
        let newest = try #require(inbox.first), oldest = try #require(inbox.last)
        #expect(try h.store.threadDetail(newest.id)?.messages.allSatisfy { $0.bodyState == .stored } == true)
        #expect(try h.store.threadDetail(oldest.id)?.messages.allSatisfy { $0.bodyState == .metadataOnly } == true)

        try await eventually("progress recorded") { progress.all.contains { $0.stage == .allMail } }
        let texts = progress.all.compactMap(\.statusText)
        #expect(texts.contains { $0.hasPrefix("Syncing ") && $0.hasSuffix(" of 4,000") })
        let inboxCounts = progress.all.filter { $0.stage == .inbox }.map(\.inboxSynced)
        #expect(inboxCounts == inboxCounts.sorted() && (inboxCounts.last ?? 0) > 50)
        #expect(relaunched.progress.stage == .complete && !relaunched.progress.isRunning)
        let log = try h.store.syncLog(account: h.account, limit: 20)
        #expect(log.contains { $0.kind == "backfill" && $0.detail == "inbox" && $0.outcome == "ok" })
        #expect(log.contains { $0.kind == "backfill" && $0.detail == "all_mail" && $0.outcome == "ok" && $0.quotaUnits > 0 })
        #expect(log.contains { $0.kind == "bodies" && $0.outcome == "ok" })
    }

    @Test func historyDuringTheWalkLandsAndAStalePageDoesNotResurrectADeletedMessage() async throws {
        let h = try SyncHarness(settings: backfillSettings(pageSize: 100), recording: true)
        let recorder = try #require(h.recorder)
        let seeded = await h.gmail.seedMailbox(count: 400, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        let syncer = h.syncer
        let gmail = h.gmail

        let victimThread = seeded.threads[5]
        #expect(seeded.archived.contains(victimThread) && !seeded.starred.contains(victimThread))
        let victim = try #require(await gmail.messageIDs(inThread: victimThread).first)
        let changes = Box<(String, String)>()
        recorder.setHook { call, n in
            guard call.method == .listMessages && n == 2 else { return }
            let fresh = await gmail.deliver(subject: "During the walk")
            let top = try? await gmail.listThreads(ListQuery(labelIDs: ["INBOX"], maxResults: 2), priority: .sync)
            let archived = top?.threads?.first { $0.id != fresh.threadID }?.id
            if let archived { await gmail.simulateWebArchive(threadID: archived) }
            changes.value = (fresh.threadID, archived ?? "")
        }
        let staleServed = Box<Bool>()
        recorder.setAfterThreadsHook { call, _ in
            guard call.priority == .backfill, call.query?.split(separator: ",").contains(Substring(victimThread)) == true,
                  await gmail.labelIDs(ofMessage: victim) != nil else { return }
            await gmail.deleteMessagePermanently(victim)
            _ = try? await syncer.sync(reason: "poll")
            staleServed.value = true
        }
        #expect(await h.syncer.runBackfill() == .complete)
        try await h.syncer.sync(reason: "poll")

        let (fresh, archived) = try #require(changes.value)
        #expect(staleServed.value == true)
        let inbox = Set(try h.fullInbox().map(\.ref.gmailThreadID.rawValue))
        #expect(inbox == Set(try await serverThreads(h.gmail, label: "INBOX")))
        #expect(inbox.contains(fresh) && !inbox.contains(archived))
        #expect(try h.message(victim) == nil)
        let serverMessages = try await serverMessageIDs(h.gmail)
        #expect(try h.localMessages(among: serverMessages) == serverMessages)
        #expect(try h.status().historyID == (await h.gmail.currentHistoryID))
    }

    @Test func theBackfillWaitsForARunningSync() async throws {
        let h = try SyncHarness(settings: backfillSettings(pageSize: 100), recording: true)
        let recorder = try #require(h.recorder)
        await h.gmail.seedMailbox(count: 120, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        let gate = AsyncGate()
        recorder.setHook { call, _ in if call.method == .listHistory { await gate.wait() } }
        let poll = Task { try await h.syncer.sync(reason: "poll") }
        try await eventually("poll held in history.list") { gate.waiting == 1 }
        recorder.reset()
        await h.syncer.startBackfill()
        try await eventually("backfill parked behind the run") { await h.syncer.backfillWaitsForRun }
        #expect(recorder.calls.isEmpty)
        gate.open()
        _ = try await poll.value
        #expect(await h.syncer.runBackfill() == .complete)
        #expect(recorder.calls.first?.method == .getLabel)
        #expect(try h.fullInbox().count == 96)
    }

    @Test func theInboxRanksAThreadByItsNewestMessageIncludingTheAccountsOwnReply() async throws {
        let h = try SyncHarness()
        let base = testNow.addingTimeInterval(-86_400)
        let a = await h.gmail.deliver(subject: "A", date: base)
        let b = await h.gmail.deliver(subject: "B", date: base.addingTimeInterval(600))
        await h.gmail.deliver(from: "Me <me@example.com>", to: "alice@example.com", subject: "Re: A", labels: ["SENT"],
                              threadID: a.threadID, date: base.addingTimeInterval(1_200))
        try await h.syncer.sync(reason: "launch")
        let local = try h.fullInbox()
        #expect(local.map(\.ref.gmailThreadID.rawValue) == [a.threadID, b.threadID])
        #expect(local.first?.sortAt == base.addingTimeInterval(1_200))
        #expect(try await serverThreads(h.gmail, label: "INBOX") == [b.threadID, a.threadID])
    }

    @Test func aRateLimitPausesTheBackfillAndItResumes() async throws {
        let clock = InstantClock(now: testNow)
        let h = try SyncHarness(settings: backfillSettings(pageSize: 100), clock: clock)
        await h.gmail.seedMailbox(count: 150, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        let progress = ProgressLog(h.syncer.observeProgress())
        defer { progress.stop() }
        await h.gmail.failNext(.listMessages, with: .rateLimited(retryAfter: .seconds(120)))
        await h.gmail.failNext(.getMessage, with: .rateLimited(retryAfter: nil))
        #expect(await h.syncer.runBackfill() == .complete)
        #expect(clock.sleeps.contains(120) && clock.sleeps.contains(60))
        let status = try h.status()
        #expect(status.backfillComplete && status.consecutiveFailures == 0 && status.lastError == nil)
        let log = try h.store.syncLog(account: h.account, limit: 30)
        #expect(log.filter { $0.kind == "backfill" && $0.errorCode == "rate_limited" && $0.detail == "paused" }.count == 2)
        try await eventually("paused progress recorded") { progress.all.contains { $0.pausedUntil != nil } }
        #expect(progress.all.first { $0.pausedUntil != nil }?.statusText == "Sync paused by Gmail's rate limit")
        let serverMessages = try await serverMessageIDs(h.gmail)
        #expect(try h.localMessages(among: serverMessages) == serverMessages)
    }

    @Test func aSliceStoreWithoutBackfillStartsWithTheInbox() async throws {
        let h = try SyncHarness(settings: backfillSettings(pageSize: 100), recording: true)
        await h.gmail.seedMailbox(count: 200, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        try h.store.updateSyncState(account: h.account) { $0.phase = .incremental }
        #expect(await h.syncer.runBackfill() == .complete)
        let calls = try #require(h.recorder).calls
        #expect(calls.contains { $0.method == .listThreads && $0.query == "INBOX" && $0.priority == .sync })
        #expect(try h.fullInbox().count == 160 && h.allMailCount() == 200)
        await h.syncer.startBackfill()
        #expect(await h.syncer.isBackfillRunning == false)
    }

    @Test func theWalkStopsAtTheMetadataHorizon() async throws {
        var settings = backfillSettings(pageSize: 100)
        settings.metadataHorizon = .seconds(2 * 86_400)
        let h = try SyncHarness(settings: settings)
        let seeded = await h.gmail.seedMailbox(count: 300, end: testNow.addingTimeInterval(-3_600), spacing: .seconds(3_600))
        try await h.syncer.sync(reason: "launch")
        #expect(await h.syncer.runBackfill() == .complete)
        #expect(try h.status().backfillComplete)
        let horizon = testNow.addingTimeInterval(-2 * 86_400)
        let oldArchived = seeded.threads[5], recentArchived = seeded.threads[295]
        #expect(seeded.archived.isSuperset(of: [oldArchived, recentArchived]))
        #expect(try h.thread(oldArchived) == nil)
        #expect(try h.thread(recentArchived) != nil)
        #expect(try h.status().backfillOldest.map { $0 <= horizon.addingTimeInterval(4 * 3_600) } == true)
    }

    @Test func theLoopStartsTheBackfillAfterTheFirstRun() async throws {
        let clock = TestClock(now: testNow)
        var settings = backfillSettings(pageSize: 100)
        settings.backfillUnitsPerMinute = 10_000_000
        let h = try SyncHarness(settings: settings, clock: clock)
        await h.gmail.seedMailbox(count: 120, end: testNow.addingTimeInterval(-3_600))
        let loop = SyncLoop(syncer: h.syncer, store: h.store, clock: clock, backfill: true)
        await loop.start()
        try await eventually("backfill complete") { h.syncer.progress.stage == .complete }
        #expect(try h.status().backfillComplete && h.fullInbox().count == 96 && h.allMailCount() == 120)
        await loop.stop()
        try await eventually("stopped") { await loop.state == .stopped }
    }

    @Test func statusTextAndPacing() {
        #expect(SyncProgress.grouped(0) == "0" && SyncProgress.grouped(999) == "999")
        #expect(SyncProgress.grouped(1_240) == "1,240" && SyncProgress.grouped(4_707) == "4,707")
        #expect(SyncProgress.grouped(1_234_567) == "1,234,567")
        var p = SyncProgress(stage: .inbox, inboxSynced: 1_240, inboxTotal: 4_707, isRunning: true)
        #expect(p.statusText == "Syncing 1,240 of 4,707")
        p.inboxTotal = nil
        #expect(p.statusText == "Syncing 1,240")
        p = SyncProgress(stage: .allMail, mailSynced: 12_000, mailTotal: 98_000, isRunning: true)
        #expect(p.statusText == "Syncing older mail, 12,000 of 98,000")
        p.isRunning = false
        #expect(p.statusText == nil)

        var pacer = BackfillPacer(unitsPerMinute: 3_000)
        let t0 = testNow
        #expect(pacer.charge(500, now: t0) == .zero)
        #expect(pacer.charge(250, now: t0) == .zero)
        #expect(pacer.charge(500, now: t0) == .seconds(10))
        #expect(pacer.charge(50, now: t0.addingTimeInterval(10)) == .seconds(1))
        #expect(pacer.units == 1_300 && pacer.calls == 4)

        #expect(BackfillPacer.cost(.getThread) == QuotaCost.units(.getThread) && BackfillPacer.cost(.getThread, count: 50) == 2_000)
        #expect(BackfillPacer.cost(.getMessage, count: 25) == 500)
        #expect(GmailClientConfig(userAgent: "test").unitsPerMinute == 6_000 && SyncSettings().backfillUnitsPerMinute * 2 == 6_000)
        #expect(SyncSettings().backfillUnitsPerMinute / BackfillPacer.cost(.getThread) == 75)
        #expect(SyncSettings().backfillUnitsPerMinute / BackfillPacer.cost(.getMessage) == 150)
    }
}
