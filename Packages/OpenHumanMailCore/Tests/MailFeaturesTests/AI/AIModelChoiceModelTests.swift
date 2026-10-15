import Foundation
import OpenHumanAI
import OpenHumanAITesting
import Testing
@testable import MailFeatures

@MainActor
@Suite struct AIModelChoiceModelTests {
    static func center(apple: AIAvailability = .available, settings: AISettings = AISettings()) -> AICenter {
        let apple = ScriptedProvider(id: .appleSystem, displayName: "Apple Intelligence", availability: apple)
        let small = ScriptedProvider(id: .local("small"), displayName: "Small model")
        let claude = ScriptedProvider(id: .agentClaude, displayName: "Claude Code",
                                      capabilities: .fake(dataLocation: .thirdParty(vendor: "Anthropic")))
        return AICenter.make(registry: ProviderRegistry(providers: [claude, small, apple]),
                             settings: AISettingsBox(store: InMemoryAISettingsStore(settings)))
    }

    @Test func listsTheModelsOnThisMacWithMailsDefaultChecked() async {
        let choice = AIModelChoiceModel(center: Self.center(), feature: .rewrite, accountKey: nil)
        await choice.refresh()
        #expect(choice.options.map(\.id) == [.appleSystem, .local("small")], "nothing off this Mac is offered")
        #expect(choice.options.map(\.name) == ["Apple on-device model", "Small model"])
        #expect(choice.options.map(\.isDefault) == [true, false])
        #expect(choice.chosen == .appleSystem)
        #expect(choice.why == "Mail's default for this feature. Runs on this Mac.")
        #expect(choice.title == "Model for Write and rewrite (⌘J)")
    }

    @Test func choosingAModelPinsItAndChoosingTheDefaultAgainClearsThePin() async {
        let center = Self.center()
        let choice = AIModelChoiceModel(center: center, feature: .rewrite, accountKey: nil)
        await choice.refresh()
        await choice.choose(.local("small"))
        #expect(center.settings.featurePins[.rewrite] == .local("small"))
        #expect(center.settings.featurePins[.summarize] == nil, "one feature at a time")
        #expect(choice.chosen == .local("small"))
        #expect(choice.why == "You chose Small model for this feature. Runs on this Mac.")
        let status = await center.features.status(for: .rewrite, accountKey: nil)
        #expect(status.providerID == .local("small"), "the next request uses the choice")
        await choice.choose(.appleSystem)
        #expect(center.settings.featurePins[.rewrite] == nil && choice.chosen == .appleSystem)
    }

    @Test func anUnreadyChoiceSaysWhyEverywhereAndNothingElseIsTried() async {
        let center = Self.center(apple: .unavailable(reason: .appleIntelligenceNotEnabled))
        let choice = AIModelChoiceModel(center: center, feature: .askInbox, accountKey: nil)
        await choice.refresh()
        #expect(choice.chosen == .appleSystem)
        #expect(choice.why == "Turn on Apple Intelligence in System Settings")
        #expect(choice.options.first?.status == "Turn on Apple Intelligence in System Settings")
        #expect(choice.options.last?.status == nil)
        let status = await center.features.status(for: .askInbox, accountKey: nil)
        #expect(status.availability == .unavailable(reason: .appleIntelligenceNotEnabled) && status.providerID == .appleSystem,
                "the error the feature shows names the same model and reason")
        #expect(await center.whyLine(for: .askInbox, accountKeys: [nil]) == choice.why)
    }

    @Test func anEarlierChoiceOffThisMacIsStillShownAndAccountsOnDeviceOnlyBlockIt() async {
        var settings = AISettings(onDeviceOnlyAccounts: ["acct-work"])
        settings.featurePins[.summarize] = .agentClaude
        settings.consents[.agentClaude] = ProviderConsent(grantedAt: fixedNow, fingerprint: nil)
        let center = Self.center(settings: settings)
        let work = AIModelChoiceModel(center: center, feature: .summarize, accountKey: "acct-work")
        await work.refresh()
        #expect(work.options.map(\.id).contains(.agentClaude) && work.chosen == .agentClaude)
        #expect(work.why == "You chose Claude Code, which runs off this Mac, but this account allows AI on this Mac only.")
        let home = AIModelChoiceModel(center: center, feature: .summarize, accountKey: "acct-home")
        await home.refresh()
        #expect(home.why == "You chose Claude Code for this feature. Leaves this Mac.")
    }

    @Test func cmdJNeverFallsBackToAnotherModelAndSaysTheSameReason() async throws {
        let apple = ScriptedProvider(id: .appleSystem, displayName: "Apple Intelligence",
                                     availability: .unavailable(reason: .appleIntelligenceNotEnabled))
        let small = ScriptedProvider(id: .local("small"), displayName: "Small model")
        let f = AIFixture(providers: [apple, small])
        await f.loaded()
        let (session, _) = try f.newMessage("thanks, see you thursday")
        let panel = try #require(f.center.togglePanel(session))
        panel.instruction = "Shorter"
        panel.generate()
        await panel.settle()
        #expect(small.requests.isEmpty && apple.requests.isEmpty)
        let choice = AIModelChoiceModel(center: f.center, feature: .rewrite, accountKey: panel.accountKey)
        await choice.refresh()
        #expect(panel.phase == .failed(choice.why))
        #expect(choice.why == "Turn on Apple Intelligence in System Settings")
    }
}
