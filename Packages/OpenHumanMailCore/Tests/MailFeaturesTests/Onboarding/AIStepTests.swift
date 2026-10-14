import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct AIStepTests {
    private func step(_ ai: FakeAIOnboarding, thread: ThreadKey? = nil) -> AIStepModel {
        AIStepModel(port: ai, sampleThread: { thread })
    }

    @Test func theOnDeviceOptionIsPreselectedOnlyWhenTheModelIsAvailable() async {
        let available = step(FakeAIOnboarding(status: .available))
        await available.load()
        #expect(available.selected == .onDeviceAuto)
        #expect(available.options.map(\.choice) == [.onDeviceAuto, .onDemand, .off])
        #expect(available.options.allSatisfy { $0.isEnabled })

        let hint = "Turn on Apple Intelligence in System Settings"
        let unavailable = step(FakeAIOnboarding(status: .unavailable(hint: hint)))
        await unavailable.load()
        #expect(unavailable.selected == .onDemand, "Only when I ask is preselected without an on-device model")
        let auto = unavailable.options.first { $0.choice == .onDeviceAuto }
        #expect(auto?.isEnabled == false && auto?.disabledReason == hint)
    }

    @Test func nothingIsStoredUntilContinueAndTheChoicePersists() async throws {
        let ai = FakeAIOnboarding(status: .available)
        let model = step(ai)
        await model.load()
        #expect(ai.log == ["status"], "preselecting stored nothing")
        let stored = await ai.draftReplies()
        #expect(stored == .onDemand)
        model.selected = .off
        await model.confirm()
        let after = await ai.draftReplies()
        #expect(model.saved == .off && after == .off)
        #expect(ai.log == ["status", "setDraftReplies:off"], "no summary for 'Not at all'")
        #expect(model.sample == nil)
    }

    @Test func aDisabledOptionCannotBeConfirmed() async {
        let ai = FakeAIOnboarding(status: .unavailable(hint: "nope"))
        let model = step(ai)
        await model.load()
        model.selected = .onDeviceAuto
        await model.confirm()
        #expect(model.saved == nil && !ai.log.contains { $0.hasPrefix("setDraftReplies") })
    }

    @Test func theStepEndsWithASummaryWrittenOnThisMacAndNoOtherProviderIsInvolved() async throws {
        let ai = FakeAIOnboarding(status: .available)
        let model = step(ai, thread: ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1")))
        await model.load()
        await model.confirm()
        #expect(model.sample == SampleSummary(text: "A short summary written on this Mac.", badge: "On this Mac"))
        #expect(ai.log == ["status", "setDraftReplies:onDeviceAuto", "summarize"], "the port has no remote member to call")
        let auto = await ai.agentCLIAutoQuickReplies()
        #expect(!auto, "no agent CLI is enabled by onboarding")
    }

    @Test func withoutAnOnDeviceModelTheStepEndsInOnlyWhenIAskWithNoSummaryAndNoRemoteCall() async throws {
        let ai = FakeAIOnboarding(status: .unavailable(hint: "Download a local model (2.1 GB)"))
        let model = step(ai, thread: ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1")))
        await model.load()
        await model.confirm()
        #expect(model.saved == .onDemand && model.sample == nil)
        #expect(model.sampleNote?.contains("isn't available") == true)
        #expect(ai.log == ["status", "setDraftReplies:onDemand"], "no summary attempted, nothing downloaded, nothing remote")
    }

    @Test func aFailingSummaryNeverBlocksTheStepOrFallsBackToAnotherProvider() async {
        let ai = FakeAIOnboarding(status: .available)
        ai.failSummaries()
        let model = step(ai, thread: ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1")))
        await model.load()
        await model.confirm()
        #expect(model.saved == .onDeviceAuto && model.sample == nil && model.sampleNote != nil && model.errorMessage == nil)
    }

    @Test func aReplayStartsFromTheStoredChoiceWhenStillAvailable() async throws {
        let ai = FakeAIOnboarding(status: .available, choice: .off)
        let model = step(ai)
        let stored = await ai.draftReplies()
        await model.load(previous: stored)
        #expect(model.selected == .off)
        let gone = step(FakeAIOnboarding(status: .unavailable(hint: "x"), choice: .onDeviceAuto))
        await gone.load(previous: .onDeviceAuto)
        #expect(gone.selected == .onDemand, "a choice that can't run now falls back to Only when I ask")
    }

    @Test func theGuideRunsTheWholeAIStepAndNothingRemoteHappensAnywhereInOnboarding() async throws {
        let ai = FakeAIOnboarding(status: .available)
        let o = OnboardingFixture(ai: ai)
        await o.model.go(to: .ai)
        #expect(o.model.ai.selected == .onDeviceAuto)
        await o.model.confirmAI()
        #expect(o.progress.load().aiAnswered)
        #expect(o.model.ai.sample?.badge == "On this Mac" || o.model.ai.sampleNote != nil)
        await o.model.next()
        o.model.finish()
        #expect(ai.log.allSatisfy { ["status", "setDraftReplies:onDeviceAuto", "summarize"].contains($0) })
        let auto = await ai.agentCLIAutoQuickReplies()
        #expect(!auto)
        #expect(o.model.isFinished)
    }

    @Test func theExplanationStatesThatAgentCLIsAreNeverTheSilentDefault() {
        #expect(AIStepModel.explanation.contains("never turned on unless you do it yourself"))
        #expect(AIStepModel.footnote.contains("never auto-generated"))
    }
}

@MainActor
struct OAuthClientImportSendsNothingTests {
    @Test func importingAClientTouchesOnlyThePortAndShowsNoSecret() async throws {
        let f = SettingsFixture()
        let secret = "SECRET-SENTINEL-9f8e7d"
        let json = Data(#"{"installed":{"client_id":"123-abc.apps.googleusercontent.com","client_secret":"\#(secret)"}}"#.utf8)
        let model = SignInModel(accounts: f.store, safeMode: .readOnly)
        let runner = Task { await model.run() }
        defer { runner.cancel() }
        await model.importClient(json: json)
        #expect(model.errorMessage == nil)
        #expect(!String(describing: model.errorMessage).contains(secret))
        #expect(!String(describing: model.clientStatus).contains(secret) && !String(describing: model.phase).contains(secret))
        #expect(try await f.accounts().count == 2, "importing signed nobody in")
        await model.importClient(json: Data(#"{"installed":{"client_secret":"\#(secret)"}}"#.utf8))
        #expect(model.errorMessage?.contains(secret) == false)
    }
}
