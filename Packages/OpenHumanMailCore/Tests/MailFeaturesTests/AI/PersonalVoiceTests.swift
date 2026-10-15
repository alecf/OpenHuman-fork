import Foundation
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import Testing
@testable import MailFeatures

@MainActor
@Suite struct PersonalVoiceTests {
    @Test func inMyVoiceUsesTheAccountsSentMailOnThisMacOnlyWithThatPreset() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let (session, _) = try f.newMessage("thx for the notes, friday works")
        let panel = try #require(f.center.togglePanel(session))
        await panel.settleVoice()
        #expect(!panel.voiceExamples.isEmpty && panel.voiceExamples.count <= DefaultAIFeatures.maxStyleExamples)
        #expect(panel.voiceExamples.allSatisfy { $0.count <= DefaultAIFeatures.styleExampleCharacters })
        #expect(panel.shownPresets.map(\.id) == AIComposerModel.presets.map(\.id) + ["voice"], "after the fixed presets")
        #expect(panel.voiceRefusal == nil && !panel.isDisabled(AIComposerModel.voicePreset))

        panel.run(AIComposerModel.voicePreset)
        await eventually { panel.phase == .done }
        let voice = try #require(provider.requests.last { $0.task == .rewrite })
        #expect(voice.untrusted.filter { $0.kind == .styleExample }.map(\.text) == panel.voiceExamples)
        #expect(RequestInspector.leaks(in: voice).isEmpty, "the examples stay inside email_data blocks")

        panel.run(try #require(AIComposerModel.presets.first { $0.id == "shorter" }))
        await eventually { provider.requests.filter { $0.task == .rewrite }.count == 2 }
        let shorter = try #require(provider.requests.last { $0.task == .rewrite })
        #expect(!shorter.untrusted.contains { $0.kind == .styleExample }, "only In my voice sends them")
        #expect(!f.recorder.calls.contains { $0.contains("send") }, "nothing is sent")

        await f.center.clearCache()
        #expect(f.center.styleExampleCache.isEmpty, "Clear AI cache forgets the examples")
    }

    @Test func inMyVoiceIsGreyedOutWhenTheRewriteWouldLeaveThisMac() async throws {
        let claude = ScriptedProvider(id: .agentClaude, capabilities: .remote())
        var settings = AISettings(providerOrder: [.agentClaude])
        settings.consents[.agentClaude] = ProviderConsent(grantedAt: fixedNow, fingerprint: nil)
        let f = AIFixture(settings: settings, providers: [claude])
        await f.loaded()
        let (session, _) = try f.newMessage("thx for the notes, friday works")
        let panel = try #require(f.center.togglePanel(session))
        await panel.settleVoice()
        #expect(panel.voiceRefusal == AIComposerModel.voiceOffMacNote)
        #expect(panel.isDisabled(AIComposerModel.voicePreset))
        panel.run(AIComposerModel.voicePreset)
        #expect(panel.phase == .failed(AIComposerModel.voiceOffMacNote))
        #expect(claude.requests.isEmpty, "nothing leaves the Mac")
    }

    @Test func aDraftFromNotesOffersNoVoicePreset() async throws {
        let f = AIFixture()
        await f.loaded()
        let (session, _) = try f.newMessage("")
        let panel = try #require(f.center.togglePanel(session))
        await panel.settleVoice()
        #expect(panel.scope == .notes && panel.voiceExamples.isEmpty, "no presets over notes, so no read")
        #expect(f.center.styleExampleCache.isEmpty)
    }

    @Test func personalInstructionsAreWholeLocalSettingsThatReachTheRewrite() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let page = AISettingsPageModel(center: f.center, environment: f.env)
        page.aboutMe = String(repeating: "a", count: 4_000)
        page.writingInstructions = "Short and warm."
        #expect(page.error == nil)
        #expect(page.aboutMe.count == 4_000, "kept whole")
        #expect(f.center.settings.writingInstructions == "Short and warm.")
        page.aboutMe = "I run a small studio."

        let (session, _) = try f.newMessage("thx for the notes")
        let panel = try #require(f.center.togglePanel(session))
        panel.run(try #require(AIComposerModel.presets.first { $0.id == "friendlier" }))
        await eventually { panel.phase == .done }
        let request = try #require(provider.requests.last { $0.task == .rewrite })
        #expect(request.trusted.contains(TrustedPart(kind: .userPreferences,
                                                     text: "About me: I run a small studio.\nHow I write: Short and warm.")))
    }
}
