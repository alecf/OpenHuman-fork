import Foundation
import OpenHumanAI
import OpenHumanAITesting
import Testing
@testable import MailFeatures

@MainActor
@Suite struct OlderMacOSTests {
    static let needsMacOS27 = "Apple's on-device model in Mail needs macOS 27"

    static func center(_ appleModel: AppleModelSupport) -> AICenter {
        let claude = ScriptedProvider(id: .agentClaude, displayName: "Claude Code",
                                      capabilities: .fake(dataLocation: .thirdParty(vendor: "Anthropic")))
        return AICenter.make(registry: ProviderRegistry(providers: [claude]),
                             settings: AISettingsBox(store: InMemoryAISettingsStore()), appleModel: appleModel)
    }

    @Test func belowMacOS27SettingsListsApplesModelFirstWithTheReason() async throws {
        let page = AISettingsPageModel(center: Self.center(.unsupported), environment: nil, listsUnavailableModels: false)
        await page.refresh()
        let apple = try #require(page.providers.first)
        #expect(apple.id == AIProviderID.appleSystem.rawValue && apple.name == "On this Mac (Apple Intelligence)")
        #expect(apple.status == Self.needsMacOS27 && !apple.isReady && apple.action == nil && !apple.badge.leavesMac)
        #expect(page.providers.contains { $0.id == AIProviderID.agentClaude.rawValue }, "Claude Code is still offered")
    }

    @Test func onMacOS27SettingsAddsNoRow() async {
        let page = AISettingsPageModel(center: Self.center(.supported), environment: nil, listsUnavailableModels: false)
        await page.refresh()
        #expect(!page.providers.contains { $0.id == AIProviderID.appleSystem.rawValue })
    }

    @Test func belowMacOS27TheOnDeviceStatusSaysWhy() async {
        let below = await Self.center(.unsupported).onDeviceStatus()
        #expect(!below.available && below.hint == Self.needsMacOS27)
        let current = await Self.center(.supported).onDeviceStatus()
        #expect(!current.available && current.hint == "No on-device model is set up")
    }

    @Test func theNewReasonHasShortAndLongWording() {
        #expect(AIWording.reason(.requiresNewerOS) == Self.needsMacOS27)
        #expect(AIModelChoiceModel.shortReason(.requiresNewerOS) == "needs macOS 27")
    }
}
