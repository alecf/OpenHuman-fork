import OpenHumanAI

public enum AppleProviders {
    public static let registersPrivateCloudComputeInV1 = false

    @discardableResult
    public static func register(in registry: ProviderRegistry, classifierUseCase: AppleModelUseCase = .general,
                                support: AppleModelSupport = .current) -> Bool {
        guard support.isSupported, #available(macOS 27, iOS 27, *) else { return false }
        registry.register(AppleSystemProvider(source: SystemModelSource()))
        registry.register(classifier: AppleSystemClassifier(useCase: classifierUseCase))
        return true
    }

    public static func makeRegistry(support: AppleModelSupport = .current) -> ProviderRegistry {
        let registry = ProviderRegistry()
        register(in: registry, support: support)
        return registry
    }

    public static func availability(support: AppleModelSupport = .current) async -> AIAvailability {
        guard support.isSupported, #available(macOS 27, iOS 27, *) else { return .unavailable(reason: .requiresNewerOS) }
        return await SystemModelSource().availability()
    }
}
