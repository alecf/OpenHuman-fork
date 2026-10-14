import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct AIPreparationQueueTests {
    private func queue(_ f: AIFixture, paused: Bool) -> AIPreparationQueue {
        let queue = f.center.preparation
        queue.now = { fixedNow }
        queue.sleep = { _ in throw CancellationError() }
        queue.isLowPowerMode = { paused }
        queue.thermalState = { .nominal }
        queue.isStarted = true
        queue.onDeviceReady = true
        return queue
    }

    private func recentRows(_ f: AIFixture, count: Int) async throws -> [ThreadRow] {
        let rows = try await f.store.threadPage(.system(.inbox), account: AIFixture.work, after: nil, limit: 200).rows
            .filter { fixedNow.timeIntervalSince($0.lastMessageAt) < 7 * 86_400 }
        try #require(rows.count >= count, "the fake Inbox has \(rows.count) recent conversations")
        return rows
    }

    @Test func priorityOrderBumpAndNewMail() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: AIInlineTests.drafts, providers: [provider])
        await f.loaded()
        let queue = queue(f, paused: true)
        let rows = try await recentRows(f, count: 5)
        let first = Array(rows.prefix(4))
        queue.inboxChanged(first, account: AIFixture.work)
        #expect(queue.pause == .lowPower && provider.requests.isEmpty, "Low Power Mode: nothing runs")
        #expect(queue.statusLine == nil, "no line while paused")
        let kinds = queue.pending.map(\.kind)
        #expect(kinds == AIPreparationQueue.Kind.allCases.flatMap { Array(repeating: $0, count: first.count) },
                "every conversation's replies first, then the summaries, the classifications, the follow-up checks")
        #expect(queue.pending.prefix(first.count).map(\.thread) == first.map(\.id), "newest first")

        queue.bump(first[2].id)
        #expect(queue.pending.prefix(4).allSatisfy { $0.thread == first[2].id }, "the opened conversation goes first")
        #expect(queue.pending.prefix(4).map(\.kind) == AIPreparationQueue.Kind.allCases)

        queue.inboxChanged(first + [rows[4]], account: AIFixture.work)
        #expect(queue.pending[4].thread == rows[4].id && queue.pending[4].kind == .replies)
        #expect(queue.pending.prefix(8).filter { $0.thread == rows[4].id }.count == 4)
        #expect(queue.remaining == 5)
    }

    @Test func mailOlderThanSevenDaysIsSkipped() async throws {
        let f = AIFixture(settings: AIInlineTests.drafts)
        await f.loaded()
        let queue = queue(f, paused: true)
        queue.now = { fixedNow.addingTimeInterval(365 * 86_400) }
        let rows = try await recentRows(f, count: 1)
        queue.inboxChanged(rows, account: AIFixture.work)
        #expect(queue.pending.isEmpty)
    }

    @Test func lowPowerAndHeatPauseOneJobRunsAtATimeWithTheQuietLine() async throws {
        let held = ScriptedProvider { request, _ in
            request.task == .replyOptions ? .hang : FakeAIProvider.cannedScript(request)
        }
        let f = AIFixture(settings: AIInlineTests.drafts, providers: [held])
        await f.loaded()
        let (thread, _) = try await f.needsReplyThread()
        let queue = queue(f, paused: false)
        queue.isLowPowerMode = { true }
        let rows = try await recentRows(f, count: 3)
        queue.inboxChanged(rows, account: AIFixture.work)
        queue.bump(thread)
        #expect(queue.pause == .lowPower)
        queue.isLowPowerMode = { false }
        for state in [ProcessInfo.ThermalState.serious, .critical] {
            queue.thermalState = { state }
            queue.pump()
            #expect(queue.pause == .thermal && queue.running.isEmpty, "\(state)")
        }
        #expect(held.requests.isEmpty)
        queue.thermalState = { .fair }
        queue.pump()
        await eventually { held.requests.contains { $0.task == .replyOptions } }
        #expect(queue.pause == nil && queue.running.count == 1, "one job at a time")
        let line = try #require(queue.statusLine)
        #expect(line.hasPrefix("Preparing replies…") && line.hasSuffix("left"))
        #expect(f.env.status.preparingLine == line, "the status bar shows it while a job runs")
        queue.cancelAll()
        #expect(queue.running.isEmpty && queue.pending.isEmpty && f.env.status.preparingLine == nil)
    }

    @Test func theHourlyBudgetStopsTheQueueUntilTheHourPasses() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: AIInlineTests.drafts, providers: [provider])
        await f.loaded()
        let queue = queue(f, paused: false)
        queue.hourlyBudget = 1
        let rows = try await recentRows(f, count: 3)
        queue.inboxChanged(rows, account: AIFixture.work)
        await eventually { queue.pause == .budget }
        let asked = provider.requests.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(queue.pause == .budget && provider.requests.count == asked, "nothing more within the hour")
        queue.now = { fixedNow.addingTimeInterval(3_700) }
        queue.pump()
        await eventually { provider.requests.count > asked }
        #expect(provider.requests.count > asked, "the next hour goes on")
        queue.cancelAll()
    }

    @Test func aPreparedConversationShowsItsRepliesInTheFirstFrame() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: AIInlineTests.drafts, providers: [provider])
        await f.loaded()
        let (thread, newest) = try await f.needsReplyThread()
        let queue = queue(f, paused: false)
        queue.bump(thread)
        await eventually { queue.pending.isEmpty && queue.running.isEmpty }
        #expect(queue.prepared.contains(thread))
        #expect(f.center.classification(of: thread, newest: newest) == .fyi, "classified on this Mac")
        let row = f.center.inlineReplies.row(for: thread, message: newest)
        #expect(row.state == .ready && row.preview?.body == InstantReplyTests.first, "no wait, no layout change")
        let asked = provider.requests.filter { $0.task == .replyOptions }.count
        f.center.conversationAppeared(thread, messageCount: 3)
        row.appear()
        #expect(provider.requests.filter { $0.task == .replyOptions }.count == asked, "opening it asks for nothing new")
        #expect(!f.recorder.calls.contains { $0.hasPrefix("send") || $0 == "scheduleSend" }, "nothing is ever sent")
    }

    @Test func cmdJIsNeverPrepared() async throws {
        #expect(!AIPreparationQueue.preparedFeatures.contains(.rewrite))
        #expect(!AIPreparationQueue.preparedFeatures.contains(.askInbox))
        for kind in AIPreparationQueue.Kind.allCases {
            #expect(AIPreparationQueue.preparedFeatures.contains(AIPreparationQueue.feature(kind)))
        }
        let provider = ScriptedProvider()
        let f = AIFixture(settings: AIInlineTests.drafts, providers: [provider])
        await f.loaded()
        let queue = queue(f, paused: false)
        let rows = try await recentRows(f, count: 3)
        queue.inboxChanged(Array(rows.prefix(3)), account: AIFixture.work)
        await eventually { queue.pending.isEmpty && queue.running.isEmpty }
        #expect(!provider.requests.isEmpty)
        #expect(!provider.requests.contains { $0.task == .rewrite || $0.task == .askInbox }, "⌘J needs the user's words")
        #expect(f.recorder.calls.isEmpty, "the queue writes nothing")
    }

    @Test func theSettingStopsItWakeResumesAndClearDropsWhatWasPrepared() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: AIInlineTests.drafts, providers: [provider])
        await f.loaded()
        let (thread, newest) = try await f.needsReplyThread()
        #expect(AISettings().prepareInAdvance, "on by default")
        let queue = queue(f, paused: false)
        queue.bump(thread)
        await eventually { queue.pending.isEmpty && queue.running.isEmpty }
        let replies = f.center.quickReplies(for: thread, replyingTo: newest)
        #expect(replies.phase == .ready)

        await queue.clearPrepared()
        #expect(replies.phase == .idle && queue.prepared.isEmpty, "Clear prepared replies")

        try f.center.update { $0.prepareInAdvance = false }
        #expect(!queue.isEnabled && queue.pending.isEmpty)
        queue.bump(thread)
        #expect(queue.pending.isEmpty, "off: nothing is queued")

        try f.center.update { $0.prepareInAdvance = true }
        queue.isLowPowerMode = { true }
        queue.systemDidWake()
        await eventually { !queue.pending.isEmpty }
        #expect(queue.onDeviceReady == true && queue.pause == .lowPower, "wake: the Inbox is watched and queued again")
        queue.cancelAll()
    }
}
