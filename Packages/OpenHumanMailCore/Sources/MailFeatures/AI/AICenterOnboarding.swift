import Foundation
import MailModel
import OpenHumanAI
import OpenHumanCore

public struct AICenterOnboarding: AIOnboardingPort {
    let center: AICenter

    public init(center: AICenter) {
        self.center = center
    }

    public func onDeviceStatus() async -> OnDeviceAIStatus {
        let status = await center.onDeviceStatus()
        return status.available ? .available : .unavailable(hint: status.hint ?? AIWording.reason(.modelNotReady))
    }

    public func draftReplies() async -> DraftRepliesChoice {
        await MainActor.run { Self.choice(center.settings.draftReplies) }
    }

    public func setDraftReplies(_ choice: DraftRepliesChoice) async throws {
        try await MainActor.run {
            try center.update { settings in
                settings.draftReplies = switch choice {
                case .onDeviceAuto: .onDeviceAuto
                case .onDemand: .onDemand
                case .off: .off
                }
            }
        }
    }

    public func agentCLIAutoQuickReplies() async -> Bool {
        await MainActor.run { center.settings.agentCLIAutoQuickReplies }
    }

    public func summarizeOnDevice(_ thread: ThreadKey) async throws -> String? {
        try await center.summarizeOnDevice(thread)
    }

    static func choice(_ mode: DraftRepliesMode) -> DraftRepliesChoice {
        switch mode {
        case .onDeviceAuto: .onDeviceAuto
        case .onDemand: .onDemand
        case .off: .off
        }
    }
}
