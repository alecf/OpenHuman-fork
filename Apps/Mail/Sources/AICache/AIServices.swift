import Foundation
import MailFeatures
import OpenHumanAI
import OpenHumanAIAgentCLI
import OpenHumanAIApple
import OpenHumanAITesting

@MainActor
enum AIServices {
    enum Model { case fake, onDevice }

    static var cacheDirectory: URL?

    static func aiCenter(model: Model, persistent: Bool,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> AICenter {
        let underTest = environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        PromptServices.install(persistent: persistent && !underTest && model != .fake, directory: cacheDirectory)
        if underTest || model == .fake {
            let delay: Duration = underTest ? .zero : .milliseconds(25)
            let provider = FakeAIProvider(displayName: "Fake model", script: { request in
                guard case .text(let text, _, _) = FakeAIProvider.cannedScript(request) else {
                    return FakeAIProvider.cannedScript(request)
                }
                return .text(text, chunkSize: 6, delay: delay)
            })
            let classifiers: [any AIClassificationProvider] = underTest ? []
                : [FakeClassifier(id: "fake.autolabels", displayName: "Fake classifier",
                                  autoLabel: { FakeClassifier.keywordAutoLabel($0) })]
            return AICenter.make(registry: ProviderRegistry(providers: [provider], classifiers: classifiers),
                                 settings: AISettingsBox(store: InMemoryAISettingsStore()))
        }
        let settings = AISettingsBox(store: persistent ? AISettingsStore() as any AISettingsStoring : InMemoryAISettingsStore())
        let registry = ProviderRegistry()
        AppleProviders.register(in: registry)
        ClassifierServices.install(registry: registry, settings: settings)
        let makeProvider: @Sendable (AIProviderID) -> (any AIProvider)? = { id in agentCLI(id, settings: settings.current) }
        for id in [AIProviderID.agentClaude, .agentCodex] where settings.current.consents[id] != nil {
            if let provider = makeProvider(id) { registry.register(provider) }
        }
        var cache: any AIResultCache = InMemoryAIResultCache()
        if persistent, let directory = cacheDirectory,
           let file = try? SQLiteAIResultCache(url: directory.appendingPathComponent(SQLiteAIResultCache.fileName)) {
            cache = file
        }
        return AICenter.make(registry: registry, settings: settings, cache: cache, makeProvider: makeProvider)
    }

    nonisolated static func agentCLI(_ id: AIProviderID, settings: AISettings) -> (any AIProvider)? {
        let kind: AgentCLIKind
        switch id {
        case .agentClaude: kind = .claude
        case .agentCodex: kind = .codex
        default: return nil
        }
        let chosen = settings.agentCLI[id] ?? AgentCLISettings()
        return AgentCLIProvider(kind: kind, configuration: AgentCLIConfiguration(
            overridePath: chosen.binaryPathOverride, model: chosen.model, policyInputCap: chosen.inputCapTokens))
    }
}
