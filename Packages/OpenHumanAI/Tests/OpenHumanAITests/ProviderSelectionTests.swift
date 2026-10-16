import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

@Suite struct ProviderSelectionTests {
    static let system = ProviderCandidate(
        id: .appleSystem, displayName: "Apple", dataLocation: .onDevice, availability: .available, consented: true,
        autoSelectable: true)
    static let pcc = ProviderCandidate(
        id: .applePCC, displayName: "PCC", dataLocation: .appleCloud, availability: .available, consented: true,
        autoSelectable: true)
    static let claude = ProviderCandidate(
        id: .agentClaude, displayName: "Claude Code", dataLocation: .thirdParty(vendor: "Anthropic"),
        availability: .available, consented: true, autoSelectable: true)
    static let codex = ProviderCandidate(
        id: .agentCodex, displayName: "Codex", dataLocation: .thirdParty(vendor: "OpenAI"), availability: .available,
        consented: true, autoSelectable: false)

    func select(
        _ feature: AIFeature, _ workload: AIWorkload, _ candidates: [ProviderCandidate], _ settings: AISettings = AISettings(),
        account: String? = nil
    ) -> ProviderSelection {
        ProviderSelectionPolicy.select(
            feature: feature, workload: workload, accountKeys: [account], candidates: candidates, settings: settings)
    }

    @Test func workloadMapping() {
        #expect(ProviderSelectionPolicy.workload(for: .classify, trigger: .user) == .background)
        #expect(ProviderSelectionPolicy.workload(for: .summarize, trigger: .automatic) == .background)
        #expect(ProviderSelectionPolicy.workload(for: .summarize, trigger: .user) == .interactive)
        #expect(ProviderSelectionPolicy.workload(for: .replyOptions, trigger: .automatic) == .autoQuickReplies)
        #expect(ProviderSelectionPolicy.workload(for: .rewrite, trigger: .automatic) == .interactive)
    }

    @Test func backgroundNeverLeavesTheMac() {
        var unavailableSystem = Self.system
        unavailableSystem.availability = .unavailable(reason: .appleIntelligenceNotEnabled)
        let settings = AISettings(pccEnabled: true)
        #expect(select(.classify, .background, [Self.claude, Self.pcc, Self.system], settings).candidate?.id == .appleSystem)
        #expect(select(.classify, .background, [Self.claude, Self.pcc, unavailableSystem], settings)
            == .unavailable(.appleIntelligenceNotEnabled, providerID: .appleSystem))
        #expect(select(.classify, .background, [Self.claude, Self.pcc], settings)
            == .unavailable(.onDeviceOnly, providerID: .agentClaude))
    }

    @Test func pccOnlyInteractiveEnabledAndConsented() {
        #expect(select(.summarize, .interactive, [Self.pcc]) == .unavailable(.disabledBySettings, providerID: .applePCC))
        let enabled = AISettings(draftReplies: .onDeviceAuto, pccEnabled: true)
        #expect(select(.summarize, .interactive, [Self.pcc], enabled).candidate?.id == .applePCC)
        #expect(select(.summarize, .background, [Self.pcc], enabled).candidate == nil)
        #expect(select(.replyOptions, .autoQuickReplies, [Self.pcc], enabled).candidate == nil)
        var unconsented = Self.pcc
        unconsented.consented = false
        #expect(select(.summarize, .interactive, [unconsented], enabled) == .unavailable(.notConsented, providerID: .applePCC))
    }

    @Test func autoDraftRepliesRules() {
        let optIn = AISettings(draftReplies: .onDemand, agentCLIAutoQuickReplies: true, autoDraftReplies: true)
        #expect(select(.replyOptions, .autoQuickReplies, [Self.system], optIn).candidate?.id == .appleSystem)
        #expect(select(.replyOptions, .autoQuickReplies, [Self.claude], optIn).candidate == nil, "never an agent CLI")
        #expect(select(.replyOptions, .autoQuickReplies, [Self.system], AISettings(draftReplies: .onDemand))
            == .unavailable(.disabledBySettings, providerID: nil), "off by default")
        #expect(select(.replyOptions, .autoQuickReplies, [Self.system], AISettings(draftReplies: .off, autoDraftReplies: true))
            == .unavailable(.disabledBySettings, providerID: nil), "Not at all wins")
        var auto = optIn
        auto.draftReplies = .onDeviceAuto
        #expect(select(.replyOptions, .autoQuickReplies, [Self.claude], auto).candidate?.id == .agentClaude,
                "the agent CLI's own opt-in still decides for 'Yes, draft replies on this Mac'")
    }

    @Test func autoQuickRepliesRules() {
        let auto = AISettings(draftReplies: .onDeviceAuto)
        #expect(select(.replyOptions, .autoQuickReplies, [Self.claude, Self.system], auto).candidate?.id == .appleSystem)
        #expect(select(.replyOptions, .autoQuickReplies, [Self.claude], auto).candidate == nil)
        var withAgents = auto
        withAgents.agentCLIAutoQuickReplies = true
        #expect(select(.replyOptions, .autoQuickReplies, [Self.claude], withAgents).candidate?.id == .agentClaude)
        #expect(select(.replyOptions, .autoQuickReplies, [Self.codex], withAgents).candidate == nil)
        withAgents.featurePins[.replyOptions] = .agentCodex
        #expect(select(.replyOptions, .autoQuickReplies, [Self.codex], withAgents).candidate?.id == .agentCodex)
        #expect(select(.replyOptions, .autoQuickReplies, [Self.system], AISettings(draftReplies: .onDemand))
            == .unavailable(.disabledBySettings, providerID: nil))
        #expect(select(.replyOptions, .interactive, [Self.system], AISettings(draftReplies: .off))
            == .unavailable(.disabledBySettings, providerID: nil))
        #expect(select(.replyOptions, .interactive, [Self.system], AISettings(draftReplies: .onDemand)).candidate != nil)
    }

    @Test func perAccountOnDeviceOnlyFailsClosed() {
        let settings = AISettings(onDeviceOnlyAccounts: ["work"])
        #expect(select(.rewrite, .interactive, [Self.claude, Self.system], settings, account: "work").candidate?.id == .appleSystem)
        #expect(select(.rewrite, .interactive, [Self.claude, Self.system], settings, account: "home").candidate?.id == .appleSystem,
                "unpinned, every account uses the default model on this Mac")
        #expect(select(.rewrite, .interactive, [Self.claude, Self.system], settings, account: nil).candidate?.id == .appleSystem)
        #expect(select(.rewrite, .interactive, [Self.claude], settings, account: "work")
            == .unavailable(.onDeviceOnly, providerID: .agentClaude))
        var pinned = settings
        pinned.featurePins[.rewrite] = .agentClaude
        #expect(select(.rewrite, .interactive, [Self.claude, Self.system], pinned, account: "home").candidate?.id == .agentClaude)
        #expect(select(.rewrite, .interactive, [Self.claude, Self.system], pinned, account: "work")
            == .unavailable(.onDeviceOnly, providerID: .agentClaude), "a pin never overrides the account's policy")
    }

    @Test func pinsNeverFallBackSilently() {
        var settings = AISettings()
        settings.featurePins[.summarize] = .agentClaude
        var unavailableClaude = Self.claude
        unavailableClaude.availability = .unavailable(reason: .notLoggedIn(name: "claude"))
        #expect(select(.summarize, .interactive, [Self.system, unavailableClaude], settings)
            == .unavailable(.notLoggedIn(name: "claude"), providerID: .agentClaude))
        #expect(select(.summarize, .interactive, [Self.system, Self.claude], settings).candidate?.id == .agentClaude)
        #expect(select(.summarize, .background, [Self.system, Self.claude], settings)
            == .unavailable(.onDeviceOnly, providerID: .agentClaude))
        settings.featurePins[.summarize] = "local.missing"
        #expect(select(.summarize, .interactive, [Self.system], settings).candidate == nil)
    }

    @Test func codexAndUnconsentedAreNeverAutoSelected() {
        var unconsentedClaude = Self.claude
        unconsentedClaude.consented = false
        #expect(select(.askInbox, .interactive, [Self.codex, unconsentedClaude, Self.system]).candidate?.id == .appleSystem)
        #expect(select(.askInbox, .interactive, [Self.codex]).candidate == nil)
        #expect(select(.rewrite, .interactive, [unconsentedClaude]) == .unavailable(.notConsented, providerID: .agentClaude))
    }

    @Test func askInboxLeavesTheMacOnlyWhenPinned() {
        var unavailableSystem = Self.system
        unavailableSystem.availability = .unavailable(reason: .appleIntelligenceNotEnabled)
        let pcc = AISettings(pccEnabled: true)
        #expect(select(.askInbox, .interactive, [Self.claude, Self.pcc, Self.system], pcc).candidate?.id == .appleSystem)
        #expect(select(.askInbox, .interactive, [Self.claude, Self.pcc], pcc) == .unavailable(.onDeviceOnly, providerID: .agentClaude),
                "a consented provider that leaves the Mac is not chosen on its own")
        #expect(select(.askInbox, .interactive, [Self.claude, unavailableSystem])
            == .unavailable(.appleIntelligenceNotEnabled, providerID: .appleSystem), "the actionable reason comes first")
        #expect(select(.rewrite, .interactive, [Self.claude]).candidate?.id == .agentClaude, "other features are unchanged")

        var pinned = AISettings()
        pinned.featurePins[.askInbox] = .agentClaude
        #expect(select(.askInbox, .interactive, [Self.system, Self.claude], pinned).candidate?.id == .agentClaude)
        var unconsentedClaude = Self.claude
        unconsentedClaude.consented = false
        #expect(select(.askInbox, .interactive, [Self.system, unconsentedClaude], pinned)
            == .unavailable(.notConsented, providerID: .agentClaude), "pinned, but the consent sheet comes first")
        pinned.onDeviceOnlyAccounts = ["work"]
        #expect(select(.askInbox, .interactive, [Self.system, Self.claude], pinned, account: "work")
            == .unavailable(.onDeviceOnly, providerID: .agentClaude), "a pin never overrides the account's policy")
        #expect(select(.askInbox, .interactive, [Self.system, Self.claude], pinned, account: nil)
            == .unavailable(.onDeviceOnly, providerID: .agentClaude), "all accounts: an unknown account fails closed")
    }

    @Test func globalSwitchesGateFeatures() {
        #expect(select(.summarize, .interactive, [Self.system], AISettings(enabled: false))
            == .unavailable(.disabledBySettings, providerID: nil))
        #expect(select(.classify, .background, [Self.system], AISettings(backgroundTriage: false)).candidate == nil)
        #expect(select(.summarize, .background, [Self.system], AISettings(autoSummarizeOnOpen: false)).candidate == nil)
        #expect(select(.summarize, .interactive, [Self.system], AISettings(autoSummarizeOnOpen: false)).candidate != nil)
    }

    @Test(arguments: [UInt64(101), 202, 303])
    func invariantsHoldForRandomInputs(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let locations: [AIDataLocation] = [.onDevice, .appleCloud, .thirdParty(vendor: "A"), .thirdParty(vendor: "B")]
        let ids: [AIProviderID] = [.appleSystem, .local("m"), .applePCC, .agentClaude, .agentCodex, "other"]
        let reasons: [AIAvailability] = [
            .available, .available, .unavailable(reason: .modelNotReady), .unavailable(reason: .notLoggedIn(name: "x")),
        ]
        for _ in 0..<5_000 {
            let candidates = (0..<Int.random(in: 0...6, using: &rng)).map { index -> ProviderCandidate in
                let id = ids[Int.random(in: 0..<ids.count, using: &rng)]
                return ProviderCandidate(
                    id: AIProviderID("\(id.rawValue)#\(index)"), displayName: "p\(index)",
                    kind: Bool.random(using: &rng) ? .languageModel : .classifier,
                    dataLocation: locations[Int.random(in: 0..<locations.count, using: &rng)],
                    availability: reasons[Int.random(in: 0..<reasons.count, using: &rng)],
                    consented: Bool.random(using: &rng), autoSelectable: Bool.random(using: &rng))
            }
            var settings = AISettings(
                enabled: Int.random(in: 0..<10, using: &rng) > 0,
                draftReplies: DraftRepliesMode.allCases[Int.random(in: 0..<3, using: &rng)],
                agentCLIAutoQuickReplies: Bool.random(using: &rng), pccEnabled: Bool.random(using: &rng),
                onDeviceOnlyAccounts: Bool.random(using: &rng) ? ["work"] : [])
            let feature = AIFeature.allCases[Int.random(in: 0..<AIFeature.allCases.count, using: &rng)]
            if let pinned = candidates.randomElement(using: &rng), Int.random(in: 0..<4, using: &rng) == 0 {
                settings.featurePins[feature] = pinned.id
            }
            let workload = AIWorkload.allCases[Int.random(in: 0..<AIWorkload.allCases.count, using: &rng)]
            let account = [nil, "work", "home"][Int.random(in: 0..<3, using: &rng)]
            let selection = ProviderSelectionPolicy.select(
                feature: feature, workload: workload, accountKeys: [account], candidates: candidates, settings: settings)
            guard let chosen = selection.candidate else { continue }
            let restricted = settings.requiresOnDevice(accountKeys: [account])
            #expect(chosen.availability == .available)
            #expect(settings.enabled)
            if workload == .background || restricted { #expect(chosen.dataLocation == .onDevice) }
            if chosen.dataLocation == .appleCloud {
                #expect(workload == .interactive && settings.pccEnabled && chosen.consented)
            }
            if chosen.dataLocation.leavesDevice { #expect(chosen.consented) }
            if feature == .askInbox, chosen.dataLocation.leavesDevice { #expect(settings.featurePins[.askInbox] == chosen.id) }
            if !chosen.autoSelectable { #expect(settings.featurePins[feature] == chosen.id) }
            if chosen.kind == .classifier { #expect(feature == .classify) }
            if workload == .autoQuickReplies {
                if feature == .replyOptions { #expect(settings.draftReplies == .onDeviceAuto) }
                if chosen.dataLocation.leavesDevice { #expect(settings.agentCLIAutoQuickReplies) }
            }
            if let pin = settings.featurePins[feature] { #expect(chosen.id == pin) }
        }
    }

    @Test func registryOrdersByDefaultRankAndUserOrder() async {
        let registry = ProviderRegistry(providers: [
            FakeAIProvider(id: .agentCodex, capabilities: remoteCapabilities(vendor: "OpenAI")),
            FakeAIProvider(id: .agentClaude, capabilities: remoteCapabilities()),
            FakeAIProvider(id: .applePCC, capabilities: .fake(dataLocation: .appleCloud)),
            FakeAIProvider(id: .local("qwen"), capabilities: .fake()),
            FakeAIProvider(id: .appleSystem, capabilities: .fake()),
        ], classifiers: [FakeClassifier()])
        let order = await registry.candidates(for: .summarize, settings: AISettings()).map(\.id)
        #expect(order == [.appleSystem, .local("qwen"), .applePCC, .agentClaude, .agentCodex])
        let classify = await registry.candidates(for: .classify, settings: AISettings()).map(\.id)
        #expect(classify.first == "fake.classifier")
        let custom = await registry.candidates(
            for: .summarize, settings: AISettings(providerOrder: [.agentClaude, .appleSystem])
        ).map(\.id)
        #expect(custom == [.agentClaude, .appleSystem, .local("qwen"), .applePCC, .agentCodex])
        let candidates = await registry.candidates(for: .summarize, settings: AISettings())
        #expect(candidates.first { $0.id == .agentCodex }?.autoSelectable == false)
        #expect(candidates.first { $0.id == .agentClaude }?.consented == false)
    }

    @Test func consentIsBoundToTheFingerprint() async {
        let claude = FakeAIProvider(id: .agentClaude, capabilities: remoteCapabilities(), consentFingerprint: "/usr/local/bin/claude")
        let registry = ProviderRegistry(providers: [claude])
        var settings = AISettings()
        settings.consents[.agentClaude] = ProviderConsent(grantedAt: fixedNow, fingerprint: "/usr/local/bin/claude")
        #expect(await registry.candidates(for: .rewrite, settings: settings).first?.consented == true)
        settings.consents[.agentClaude] = ProviderConsent(grantedAt: fixedNow, fingerprint: "/opt/homebrew/bin/claude")
        #expect(await registry.candidates(for: .rewrite, settings: settings).first?.consented == false)
    }
}
