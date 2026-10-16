import Foundation
import OpenHumanAI
import OpenHumanAITesting
import Synchronization
import Testing
@testable import MailFeatures

@MainActor
@Suite struct AIModelChoiceModelTests {
    static let anthropic = AIDataLocation.thirdParty(vendor: "Anthropic")

    static func center(apple: AIAvailability = .available, settings: AISettings = AISettings(),
                       registersClaude: Bool = true, offersClaude: Bool = false,
                       classifiers: [any AIClassificationProvider] = []) -> AICenter {
        let apple = ScriptedProvider(id: .appleSystem, displayName: "Apple Intelligence", availability: apple)
        let small = ScriptedProvider(id: .local("small"), displayName: "Small model")
        let claude = ScriptedProvider(id: .agentClaude, displayName: "Claude Code", capabilities: .fake(dataLocation: anthropic))
        let providers: [any AIProvider] = registersClaude ? [claude, small, apple] : [small, apple]
        return AICenter.make(registry: ProviderRegistry(providers: providers, classifiers: classifiers),
                             settings: AISettingsBox(store: InMemoryAISettingsStore(settings)),
                             makeProvider: { id in offersClaude && id == .agentClaude ? claude : nil })
    }

    static func consented(_ settings: AISettings = AISettings()) -> AISettings {
        var settings = settings
        settings.consents[.agentClaude] = ProviderConsent(grantedAt: fixedNow, fingerprint: nil)
        return settings
    }

    @Test func listsEveryModelMailKnowsWithMailsDefaultCheckedAndAPlainReasonForTheRest() async {
        let choice = AIModelChoiceModel(center: Self.center(), feature: .rewrite, accountKey: nil)
        await choice.refresh()
        #expect(choice.options.map(\.id) == [.appleSystem, .local("small"), .agentClaude], "this Mac first, then off it")
        #expect(choice.options.map(\.name) == ["Apple on-device model", "Small model", "Claude Code"])
        #expect(choice.options.map(\.isDefault) == [true, false, false])
        #expect(choice.options.map(\.isEnabled) == [true, true, false])
        #expect(choice.options.last?.status == "needs your OK")
        #expect(choice.chosen == .appleSystem && !choice.isFixed)
        #expect(choice.why == "Mail's default · on this Mac")
        #expect(choice.title == "Model for Write and rewrite (⌘J in a draft)")
    }

    @Test func aModelMailCanSetUpIsListedBeforeItIsAllowedAndCannotBeChosenYet() async throws {
        let center = Self.center(registersClaude: false, offersClaude: true)
        let choice = AIModelChoiceModel(center: center, feature: .askInbox, accountKey: nil)
        await choice.refresh()
        let claude = try #require(choice.options.first { $0.id == .agentClaude })
        #expect(!claude.isEnabled && claude.status == "needs your OK")
        await choice.choose(.agentClaude)
        #expect(center.settings.featurePins[.askInbox] == nil && choice.chosen == .appleSystem)
    }

    @Test func modelsOffThisMacAreAllowedAndStoppedUnderModelsThenOfferedForEachFeature() async throws {
        let center = Self.center(registersClaude: false, offersClaude: true)
        let page = AISettingsPageModel(center: center, environment: nil, listsUnavailableModels: false)
        await page.refresh()
        let row = try #require(page.providers.first { $0.id == AIProviderID.agentClaude.rawValue })
        #expect(row.action == .allow && row.status == AISettingsPageModel.notAllowed && row.badge.leavesMac)
        await page.allow(row.id)
        #expect(page.consent?.providerID == .agentClaude)
        await page.acceptConsent()
        #expect(center.settings.consents[.agentClaude] != nil && page.consent == nil)
        #expect(page.providers.first { $0.id == row.id }?.action == .stopUsing)

        let choice = AIModelChoiceModel(center: center, feature: .rewrite, accountKey: nil)
        await choice.refresh()
        #expect(choice.options.first { $0.id == .agentClaude }?.isEnabled == true)
        await choice.choose(.agentClaude)
        #expect(center.settings.featurePins[.rewrite] == .agentClaude)

        await page.stopUsing(row.id)
        #expect(center.settings.consents[.agentClaude] == nil && center.settings.featurePins[.rewrite] == nil,
                "stopping a model puts its features back on Mail's default")
    }

    @Test func declineKeepsTheModelUnallowed() async throws {
        let center = Self.center(registersClaude: false, offersClaude: true)
        let page = AISettingsPageModel(center: center, environment: nil, listsUnavailableModels: false)
        await page.refresh()
        await page.allow(AIProviderID.agentClaude.rawValue)
        page.declineConsent()
        #expect(page.consent == nil && center.settings.consents.isEmpty)
    }

    @Test func aSingleModelIsShownAsPlainTextWithAReason() async {
        let apple = ScriptedProvider(id: .appleSystem, displayName: "Apple Intelligence")
        let center = AICenter.make(registry: ProviderRegistry(providers: [apple]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore()))
        let choice = AIModelChoiceModel(center: center, feature: .summarize, accountKey: nil)
        await choice.refresh()
        #expect(choice.isFixed && choice.chosenName == "Apple on-device model")
        #expect(choice.onlyChoiceText == "Apple on-device model is the only model Mail can use for this.")
    }

    @Test func choosingAModelPinsItAndChoosingTheDefaultAgainClearsThePin() async {
        let center = Self.center()
        let choice = AIModelChoiceModel(center: center, feature: .rewrite, accountKey: nil)
        await choice.refresh()
        await choice.choose(.local("small"))
        #expect(center.settings.featurePins[.rewrite] == .local("small"))
        #expect(center.settings.featurePins[.summarize] == nil, "one feature at a time")
        #expect(choice.chosen == .local("small"))
        #expect(choice.why == "Your choice · on this Mac")
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
        #expect(choice.options.first?.status == "Apple Intelligence is off" && choice.options.first?.isEnabled == true)
        #expect(choice.options.first { $0.id == .local("small") }?.status == nil)
        let status = await center.features.status(for: .askInbox, accountKey: nil)
        #expect(status.availability == .unavailable(reason: .appleIntelligenceNotEnabled) && status.providerID == .appleSystem,
                "the error the feature shows names the same model and reason")
        #expect(await center.whyLine(for: .askInbox, accountKeys: [nil]) == choice.why)
    }

    @Test func anEarlierChoiceOffThisMacIsStillShownAndAccountsOnDeviceOnlyBlockIt() async {
        var settings = Self.consented(AISettings(onDeviceOnlyAccounts: ["acct-work"]))
        settings.featurePins[.summarize] = .agentClaude
        let center = Self.center(settings: settings)
        let work = AIModelChoiceModel(center: center, feature: .summarize, accountKey: "acct-work")
        await work.refresh()
        #expect(work.options.map(\.id).contains(.agentClaude) && work.chosen == .agentClaude)
        #expect(work.why == "You chose Claude Code, which runs off this Mac, but this account allows AI on this Mac only.")
        #expect(work.options.first { $0.id == .agentClaude }?.status == "this account allows AI on this Mac only")
        let home = AIModelChoiceModel(center: center, feature: .summarize, accountKey: "acct-home")
        await home.refresh()
        #expect(home.why == "Your choice · leaves this Mac")
    }

    @Test func choosingOffThisMacInSettingsStillFailsClosedForAnOnDeviceOnlyAccount() async {
        let center = Self.center(settings: Self.consented(AISettings(onDeviceOnlyAccounts: ["acct-work"])))
        let popover = AIModelChoiceModel(center: center, feature: .rewrite, accountKey: "acct-work")
        await popover.refresh()
        #expect(popover.options.first { $0.id == .agentClaude }?.isEnabled == false)
        await popover.choose(.agentClaude)
        #expect(center.settings.featurePins[.rewrite] == nil, "a greyed-out model can't be chosen")

        let settings = AIModelChoiceModel(center: center, feature: .rewrite, accountKey: nil)
        await settings.refresh()
        #expect(settings.options.first { $0.id == .agentClaude }?.isEnabled == true)
        await settings.choose(.agentClaude)
        #expect(center.settings.featurePins[.rewrite] == .agentClaude)
        #expect(settings.why == "Your choice · leaves this Mac")
        #expect(settings.note?.contains("On-device AI only") == true)
        let work = await center.features.status(for: .rewrite, accountKey: "acct-work")
        #expect(work.availability == .unavailable(reason: .onDeviceOnly) && work.providerID == .agentClaude,
                "the account still fails closed, with no other model tried")
        let home = await center.features.status(for: .rewrite, accountKey: "acct-home")
        #expect(home.providerID == .agentClaude && home.availability == .available)
    }

    @Test func theQuickRepliesModelIsTheOnlySwitchForQuickRepliesOffThisMac() async {
        let center = Self.center(settings: Self.consented(AISettings(draftReplies: .onDeviceAuto)))
        let choice = AIModelChoiceModel(center: center, feature: .replyOptions, accountKey: nil)
        await choice.refresh()
        #expect(!center.settings.agentCLIAutoQuickReplies)
        await choice.choose(.agentClaude)
        #expect(center.settings.featurePins[.replyOptions] == .agentClaude && center.settings.agentCLIAutoQuickReplies)
        #expect(choice.note == "Each conversation you open is sent to Anthropic for quick replies.")
        let selection = ProviderSelectionPolicy.select(
            feature: .replyOptions, workload: .autoQuickReplies, accountKeys: ["acct-home"],
            candidates: await center.registry?.candidates(for: .replyOptions, settings: center.settings) ?? [],
            settings: center.settings)
        #expect(selection.candidate?.id == .agentClaude, "quick replies made on open use the same chosen model")
        await choice.choose(.appleSystem)
        #expect(center.settings.featurePins[.replyOptions] == nil && !center.settings.agentCLIAutoQuickReplies)
        #expect(choice.note == nil)
    }

    @Test func triageOffersApplesModelAndTheDownloadedOneWithNoAutomatic() async {
        let apple = FakeClassifier(id: .appleSystemClassifier, displayName: "Apple")
        let downloaded = FakeClassifier(id: "local.tiny.classifier", displayName: "Downloaded model (Tiny)")
        let center = Self.center(classifiers: [downloaded, apple])
        let changed = Mutex(0)
        let choice = AIModelChoiceModel(center: center, feature: .classify, accountKey: nil)
        choice.onChange = { changed.withLock { $0 += 1 } }
        await choice.refresh()
        #expect(choice.options.map(\.id) == [.appleSystemClassifier, "local.tiny.classifier"])
        #expect(choice.options.map(\.name) == ["Apple on-device model", "Downloaded model (Tiny)"])
        #expect(choice.options.map(\.isDefault) == [true, false])
        #expect(choice.chosen == .appleSystemClassifier && choice.why == "Mail's default · on this Mac")
        await choice.choose("local.tiny.classifier")
        #expect(center.settings.classifier == .localModel && center.settings.featurePins[.classify] == nil)
        #expect(choice.chosen == "local.tiny.classifier" && choice.why == "Your choice · on this Mac")
        #expect(changed.withLock { $0 } == 1)
        #expect(await center.whyLine(for: .classify, accountKeys: [nil]) == choice.why, "traces explain triage the same way")
        await choice.choose(.appleSystemClassifier)
        #expect(center.settings.classifier == .appleModel)
    }

    @Test func aDownloadedModelThatIsNotDownloadedIsGreyedOut() async {
        let apple = FakeClassifier(id: .appleSystemClassifier, displayName: "Apple")
        let missing = FakeClassifier(id: "local.tiny.classifier", displayName: "Downloaded model (Tiny)",
                                     availability: .unavailable(reason: .modelNotDownloaded(sizeBytes: 1)))
        let choice = AIModelChoiceModel(center: Self.center(classifiers: [apple, missing]), feature: .classify,
                                        accountKey: nil)
        await choice.refresh()
        #expect(choice.options.last?.isEnabled == false && choice.options.last?.status == "not downloaded")
    }

    @Test func optionsPutThisMacFirstAndNeverOfferOffDeviceModelsForFeaturesThatStayHere() {
        let candidates = [
            ProviderCandidate(id: .agentClaude, displayName: "Claude Code", dataLocation: Self.anthropic,
                              availability: .available, consented: true, autoSelectable: true),
            ProviderCandidate(id: .appleSystem, displayName: "Apple", dataLocation: .onDevice,
                              availability: .available, consented: true, autoSelectable: true),
            ProviderCandidate(id: .agentCodex, displayName: "Codex", dataLocation: .thirdParty(vendor: "OpenAI"),
                              availability: .unavailable(reason: .binaryNotFound(name: "codex")), consented: true,
                              autoSelectable: false),
        ]
        let name = { (id: AIProviderID) in id.rawValue }
        let rewrite = AIModelChoiceModel.options(feature: .rewrite, choice: .appleSystem, defaultModel: .appleSystem,
                                                 candidates: candidates, onDeviceOnlyAccount: false,
                                                 settings: AISettings(), name: name)
        #expect(rewrite.map(\.id) == [.appleSystem, .agentClaude, .agentCodex])
        #expect(rewrite.map(\.isEnabled) == [true, true, false] && rewrite.last?.status == "not installed")
        let search = AIModelChoiceModel.options(feature: .searchPlan, choice: .appleSystem, defaultModel: .appleSystem,
                                                candidates: candidates, onDeviceOnlyAccount: false,
                                                settings: AISettings(), name: name)
        #expect(search.filter(\.isEnabled).map(\.id) == [.appleSystem])
        #expect(search.first { $0.id == .agentClaude }?.status == "runs on this Mac only")
    }

    @Test func backgroundFeaturesNameTheirModelAndStayOnThisMac() async {
        let center = Self.center()
        let rows = await center.backgroundModels()
        #expect(rows.map(\.title) == ["One-line summaries", "Search as a sentence", "Follow-up checks", "Scheduling replies"])
        #expect(rows.allSatisfy { $0.model == "Apple on-device model" })
        #expect(rows.first?.detail == "Mail's default · in the background, on this Mac")

        var pinned = Self.consented()
        pinned.featurePins[.summarize] = .agentClaude
        let lines = await Self.center(settings: pinned).backgroundModels()
        #expect(lines.first?.detail.hasPrefix("Off:") == true, "one-line summaries never leave the Mac")
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
