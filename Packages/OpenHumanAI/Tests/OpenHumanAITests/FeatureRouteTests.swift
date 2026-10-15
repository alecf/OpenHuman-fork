import Foundation
import Testing

@testable import OpenHumanAI

@Suite struct FeatureRouteTests {
    static let system = ProviderSelectionTests.system
    static let claude = ProviderSelectionTests.claude
    static let local = ProviderCandidate(
        id: .local("small"), displayName: "Small", dataLocation: .onDevice, availability: .available, consented: true,
        autoSelectable: true)

    func route(_ feature: AIFeature, _ candidates: [ProviderCandidate], _ settings: AISettings = AISettings(),
               workload: AIWorkload = .interactive, account: String? = nil) -> FeatureRoute {
        FeatureRoute.explain(feature: feature, workload: workload, accountKeys: [account], candidates: candidates,
                             settings: settings)
    }

    @Test func everyLanguageFeatureHasAnExplicitDefaultOnThisMac() {
        for feature in AIFeature.allCases where feature != .classify {
            #expect(AIModelDefaults.pins[feature] == .appleSystem)
        }
        #expect(AIModelDefaults.pins[.classify] == nil, "auto labels keep their own classifier choice")
    }

    @Test func theDefaultIsUsedAndNamedAsTheDefault() {
        let chosen = route(.rewrite, [Self.claude, Self.local, Self.system])
        #expect(chosen.origin == .mailDefault && chosen.choice == .appleSystem && chosen.defaultModel == .appleSystem)
        #expect(chosen.selection.candidate?.id == .appleSystem)
    }

    @Test func anUnreadyDefaultFailsWithItsOwnReasonInsteadOfFallingBack() {
        var unready = Self.system
        unready.availability = .unavailable(reason: .appleIntelligenceNotEnabled)
        let chosen = route(.rewrite, [Self.claude, Self.local, unready])
        #expect(chosen.selection == .unavailable(.appleIntelligenceNotEnabled, providerID: .appleSystem))
        #expect(chosen.choice == .appleSystem && chosen.origin == .mailDefault)
    }

    @Test func yourChoiceWinsAndIsNamedAsYours() {
        var settings = AISettings()
        settings.featurePins[.summarize] = .local("small")
        let chosen = route(.summarize, [Self.system, Self.local], settings)
        #expect(chosen.origin == .yourChoice && chosen.choice == .local("small") && chosen.defaultModel == .appleSystem)
        #expect(chosen.selection.candidate?.id == .local("small"))
        #expect(route(.rewrite, [Self.system, Self.local], settings).origin == .mailDefault, "pins are per feature")
    }

    @Test func aPinnedModelOffThisMacStillObeysOnDeviceOnlyAccounts() {
        var settings = AISettings(onDeviceOnlyAccounts: ["work"])
        settings.featurePins[.rewrite] = .agentClaude
        #expect(route(.rewrite, [Self.system, Self.claude], settings, account: "work").selection
            == .unavailable(.onDeviceOnly, providerID: .agentClaude))
        #expect(route(.rewrite, [Self.system, Self.claude], settings, account: "home").selection.candidate?.id
            == .agentClaude)
    }

    @Test func aBuildWithoutApplesModelStandsInItsFirstOnDeviceModel() {
        let chosen = route(.askInbox, [Self.claude, Self.local])
        #expect(chosen.origin == .mailDefault && chosen.choice == .local("small"))
        let offOnly = route(.rewrite, [Self.claude])
        #expect(offOnly.origin == .firstReady && offOnly.defaultModel == nil)
    }

    @Test func autoLabelsKeepTheFirstReadyClassifier() {
        let classifier = ProviderCandidate(
            id: "local.classifier", displayName: "Classifier", kind: .classifier, dataLocation: .onDevice,
            availability: .available, consented: true, autoSelectable: true)
        var unready = Self.system
        unready.availability = .unavailable(reason: .modelNotReady)
        let chosen = route(.classify, [unready, classifier], workload: .background)
        #expect(chosen.origin == .firstReady && chosen.selection.candidate?.id == "local.classifier")
    }

    @Test func theFeatureSwitchComesBeforeTheModel() {
        let chosen = route(.summarize, [Self.system], AISettings(enabled: false))
        #expect(chosen.selection == .unavailable(.disabledBySettings, providerID: nil) && chosen.choice == .appleSystem)
    }

    @Test func selectAndExplainAlwaysAgree() {
        var settings = AISettings(onDeviceOnlyAccounts: ["work"])
        settings.featurePins[.askInbox] = .agentClaude
        for feature in AIFeature.allCases {
            for account in [nil, "work", "home"] {
                let candidates = [Self.claude, Self.local, Self.system]
                #expect(ProviderSelectionPolicy.select(feature: feature, workload: .interactive, accountKeys: [account],
                                                       candidates: candidates, settings: settings)
                    == route(feature, candidates, settings, account: account).selection)
            }
        }
    }
}
