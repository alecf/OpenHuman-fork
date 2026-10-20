import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIApple

@Suite struct AppleProviderGateTests {
    @Test func belowMacOS27NoAppleProviderOrClassifierIsRegistered() {
        let registry = ProviderRegistry()
        #expect(!AppleProviders.register(in: registry, support: .unsupported))
        #expect(registry.providers.isEmpty)
        #expect(registry.classifiers.isEmpty)
        #expect(AppleProviders.makeRegistry(support: .unsupported).providers.isEmpty)
    }

    @Test func belowMacOS27TheAppleModelSaysItNeedsANewerSystem() async {
        #expect(await AppleProviders.availability(support: .unsupported) == .unavailable(reason: .requiresNewerOS))
        #expect(AppleModelSupport.unsupported.unavailableReason == .requiresNewerOS)
        #expect(AppleModelSupport.supported.unavailableReason == nil)
    }
}
