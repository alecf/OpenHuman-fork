import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct ThreadLineSummariesTests {
    nonisolated static let answer = "Dana and Robin move the launch review to Thursday."

    private func fixture() -> (AIFixture, ScriptedProvider, ThreadLineSummaries) {
        let scripted = ScriptedProvider { _, _ in .text(Self.answer) }
        let f = AIFixture(settings: AISettings(draftReplies: .onDeviceAuto, instantReplyStrip: true), providers: [scripted])
        let lines = f.center.threadLines
        lines.sleep = { _ in throw CancellationError() }
        return (f, scripted, lines)
    }

    @Test func theOpenConversationGetsItsLineOnceAndThenFromTheSessionCache() async throws {
        let (f, scripted, lines) = fixture()
        await f.loaded()
        let thread = try await f.thread()
        lines.request(thread)
        await eventually { lines.line(for: thread) != nil || lines.states[thread] == .unavailable }
        #expect(lines.line(for: thread) == Self.answer)
        let runs = scripted.requests.count
        #expect(runs == 1)
        lines.leave(thread)
        lines.request(thread)
        await eventually { lines.line(for: thread) != nil }
        #expect(scripted.requests.count == runs, "the same newest message: no second run")
    }

    @Test func lowPowerPausesTheBackgroundButNotTheOpenConversation() async throws {
        let (f, scripted, lines) = fixture()
        await f.loaded()
        lines.isConstrained = { true }
        lines.backgroundLimit = 5
        await lines.precomputeInbox()
        #expect(lines.isPausedForPower)
        #expect(scripted.requests.isEmpty, "nothing runs in the background in Low Power Mode")
        let thread = try await f.thread()
        lines.request(thread)
        await eventually { lines.line(for: thread) != nil }
        #expect(lines.line(for: thread) == Self.answer, "the conversation on screen still gets its line")
    }

    @Test func theBackgroundRunsOneAtATimeAndStopsWhenCancelled() async throws {
        let (f, _, lines) = fixture()
        await f.loaded()
        lines.isConstrained = { false }
        lines.backgroundLimit = 6
        await lines.precomputeInbox()
        #expect(lines.states.values.filter { $0 == .generating }.count <= lines.maxConcurrent)
        lines.cancelBackground()
        await eventually { !lines.states.values.contains(.generating) }
        #expect(!lines.isPausedForPower)
    }

    @Test func settingsTurnItOff() async throws {
        let (f, scripted, lines) = fixture()
        await f.loaded()
        try await f.store.set(AppSettings.aiSummarizeEveryConversation, false)
        let thread = try await f.thread()
        lines.request(thread)
        try await Task.sleep(for: .milliseconds(200))
        #expect(lines.line(for: thread) == nil && scripted.requests.isEmpty)
    }
}
