import Foundation
import MailModel
import Observation

public struct UnavailableAIOnboarding: AIOnboardingPort {
    public init() {}
    public func onDeviceStatus() async -> OnDeviceAIStatus { .unavailable(hint: "AI isn't set up in this build yet") }
    public func draftReplies() async -> DraftRepliesChoice { .onDemand }
    public func setDraftReplies(_ choice: DraftRepliesChoice) async throws { throw MailPortError.unsupported("AI settings") }
    public func agentCLIAutoQuickReplies() async -> Bool { false }
    public func summarizeOnDevice(_ thread: ThreadKey) async throws -> String? { nil }
}

@MainActor @Observable
public final class WelcomeGuideCenter {
    public private(set) var model: OnboardingModel?
    public var isPresented: Bool {
        get { model != nil }
        set { if !newValue { dismiss() } }
    }

    @ObservationIgnored private unowned let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func present() {
        guard model == nil else { return }
        let system = environment.system
        var progress = environment.onboardingProgress.load()
        progress.isOpen = true
        environment.onboardingProgress.save(progress)
        let model = OnboardingModel(
            store: environment.onboardingProgress,
            ports: OnboardingModel.Ports(
                data: environment.data, accounts: environment.accounts,
                ai: environment.aiOnboarding ?? UnavailableAIOnboarding(), notifier: system.platform.notifier,
                loginItem: system.platform.loginItem,
                signedIn: { true },
                calendars: environment.calendarConnections, settings: environment.settings,
                openAISettings: { [weak environment] in environment?.settingsNavigator.open(SettingsPageID.ai.rawValue) }))
        self.model = model
        Task { await model.enter() }
    }

    public func presentFromStart() {
        if let model {
            Task { await model.go(to: .welcome) }
            return
        }
        var progress = environment.onboardingProgress.load()
        progress.step = .welcome
        progress.completed = false
        progress.skipped = []
        progress.setupAccount = nil
        environment.onboardingProgress.save(progress)
        present()
    }

    public func presentIfFirstRun() {
        guard !environment.isFake, OnboardingModel.shouldAutoPresent(environment.onboardingProgress) else { return }
        var progress = environment.onboardingProgress.load()
        progress.shown = true
        environment.onboardingProgress.save(progress)
        present()
    }

    public func dismiss() {
        model?.close()
        model = nil
    }
}
