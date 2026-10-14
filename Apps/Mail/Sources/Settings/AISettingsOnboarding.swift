import Foundation
import MailModel
import OpenHumanAI
import OpenHumanAIApple
import OpenHumanCore

struct AISettingsOnboarding: AIOnboardingPort {
    let store: AISettingsStore
    let availability: @Sendable () async -> AIAvailability

    init(store: AISettingsStore = AISettingsStore(), availability: @escaping @Sendable () async -> AIAvailability = {
        await SystemModelSource().availability()
    }) {
        self.store = store
        self.availability = availability
    }

    func onDeviceStatus() async -> OnDeviceAIStatus {
        switch await availability() {
        case .available: return .available
        case .unavailable(let reason): return .unavailable(hint: Self.hint(reason))
        }
    }

    func draftReplies() async -> DraftRepliesChoice {
        switch store.load().draftReplies {
        case .onDeviceAuto: .onDeviceAuto
        case .onDemand: .onDemand
        case .off: .off
        }
    }

    func setDraftReplies(_ choice: DraftRepliesChoice) async throws {
        var settings = store.load()
        settings.draftReplies = switch choice {
        case .onDeviceAuto: .onDeviceAuto
        case .onDemand: .onDemand
        case .off: .off
        }
        try store.save(settings)
    }

    func agentCLIAutoQuickReplies() async -> Bool { store.load().agentCLIAutoQuickReplies }

    func summarizeOnDevice(_ thread: ThreadKey) async throws -> String? { nil }

    static func hint(_ reason: AIAvailability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "This Mac can't run Apple Intelligence"
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings"
        case .modelNotReady: "Apple's on-device model isn't ready yet; try again later"
        case .localeNotSupported: "Apple Intelligence doesn't support this language yet"
        case .modelNotDownloaded: "Download a local model in Settings › AI"
        default: "The on-device model isn't available"
        }
    }
}
