import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct AutoDraftRepliesTests {
    private static func settings(autoDraft: Bool, replies: DraftRepliesMode = .onDemand, prepare: Bool = true) -> AISettings {
        AISettings(draftReplies: replies, prepareInAdvance: prepare, autoDraftReplies: autoDraft)
    }

    private func queue(_ f: AIFixture, lowPower: Bool = false) -> AIPreparationQueue {
        let queue = f.center.preparation
        queue.now = { fixedNow }
        queue.sleep = { _ in throw CancellationError() }
        queue.isLowPowerMode = { lowPower }
        queue.thermalState = { .nominal }
        queue.isStarted = true
        queue.onDeviceReady = true
        return queue
    }

    @Test func offByDefaultAndAdditiveInStoredSettings() throws {
        #expect(AISettings().autoDraftReplies == false, "opt-in")
        #expect(AISettings().writesRepliesAutomatically == false, "the default replies mode asks first")
        let old = try JSONDecoder().decode(AISettings.self, from: Data(#"{"enabled":true,"draftReplies":"onDemand"}"#.utf8))
        #expect(old.autoDraftReplies == false, "a stored value without it decodes as off")
        var on = AISettings()
        on.autoDraftReplies = true
        let back = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(on))
        #expect(back.autoDraftReplies)
    }

    @Test func theAutomaticRuleIsOnDeviceAutoOrTheOptInButNeverWithRepliesOff() {
        #expect(AISettings(draftReplies: .onDeviceAuto).writesRepliesAutomatically)
        #expect(AISettings(draftReplies: .onDemand, autoDraftReplies: true).writesRepliesAutomatically)
        #expect(!AISettings(draftReplies: .off, autoDraftReplies: true).writesRepliesAutomatically, "Not at all wins")
        #expect(!AISettings(draftReplies: .onDemand).writesRepliesAutomatically)
    }

    @Test func offNothingIsWrittenAhead() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: Self.settings(autoDraft: false), providers: [provider])
        await f.loaded()
        let queue = queue(f)
        let rows = try await f.store.threadPage(.system(.inbox), account: AIFixture.work, after: nil, limit: 200).rows
        queue.inboxChanged(Array(rows.prefix(5)), account: AIFixture.work)
        await eventually { queue.pending.isEmpty && queue.running.isEmpty }
        #expect(provider.requests.filter { $0.task == .replyOptions }.isEmpty)
        #expect(!f.center.showsInlineReplies)
    }

    @Test func onItWritesRepliesAheadAndOnlyRepliesAndShowsThemAsSuggestions() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: Self.settings(autoDraft: true, prepare: false), providers: [provider])
        await f.loaded()
        let (thread, newest) = try await f.needsReplyThread()
        let queue = queue(f)
        #expect(queue.isEnabled, "the opt-in alone starts the queue")
        let rows = try await f.store.threadPage(.system(.inbox), account: AIFixture.work, after: nil, limit: 200).rows
            .filter { fixedNow.timeIntervalSince($0.lastMessageAt) < 7 * 86_400 }
        queue.inboxChanged(Array(rows.prefix(4)), account: AIFixture.work)
        #expect(Set(queue.pending.map(\.kind)) == [.replies], "no summaries, classifications or follow-up checks")
        queue.bump(thread)
        await eventually { queue.pending.isEmpty && queue.running.isEmpty }
        let replies = f.center.quickReplies(for: thread, replyingTo: newest)
        #expect(replies.phase == .ready)
        let row = f.center.inlineReplies.row(for: thread, message: newest)
        #expect(row.state == .ready && row.preview != nil, "shown as a suggestion under the newest message")
        #expect(provider.requests.allSatisfy { $0.task == .replyOptions }, "only replies were asked for")
        #expect(f.recorder.calls.isEmpty, "nothing is sent, saved or changed")
    }

    @Test func lowPowerModePausesIt() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: Self.settings(autoDraft: true), providers: [provider])
        await f.loaded()
        let (thread, _) = try await f.needsReplyThread()
        let queue = queue(f, lowPower: true)
        queue.bump(thread)
        #expect(queue.pause == .lowPower && queue.running.isEmpty)
        #expect(provider.requests.isEmpty, "nothing runs on battery saver")
    }

    @Test func notAtAllStillWinsAndTheSwitchTurnsTheQueueOffAgain() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: Self.settings(autoDraft: true, replies: .off), providers: [provider])
        await f.loaded()
        #expect(!f.center.showsInlineReplies)
        try f.center.update { $0.draftReplies = .onDemand }
        #expect(f.center.showsInlineReplies)
        let queue = queue(f)
        try f.center.update { $0.autoDraftReplies = false; $0.prepareInAdvance = false }
        #expect(!queue.isEnabled && queue.pending.isEmpty, "off again: the queue stops")
        #expect(!f.center.showsInlineReplies)
    }

    @Test func usingOneOpensALocalReplyAndNeverSends() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: Self.settings(autoDraft: true), providers: [provider])
        await f.loaded()
        let (thread, newest) = try await f.needsReplyThread()
        let queue = queue(f)
        queue.bump(thread)
        await eventually { queue.pending.isEmpty && queue.running.isEmpty }
        let row = f.center.inlineReplies.row(for: thread, message: newest)
        try #require(row.state == .ready)
        let before = f.recorder.calls.count
        let session = await row.accept()
        #expect(session?.isAutoDraft == true, "a local Auto Draft the user edits and sends")
        #expect(!f.recorder.calls.dropFirst(before).contains { $0.hasPrefix("send") || $0 == "scheduleSend" }, "never sent")
    }
}
