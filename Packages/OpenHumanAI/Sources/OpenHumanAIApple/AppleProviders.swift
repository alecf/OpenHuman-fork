import OpenHumanAI

public enum AppleProviders {
    public static let registersPrivateCloudComputeInV1 = false

    public static func register(in registry: ProviderRegistry, classifierUseCase: SystemModelSource.UseCase = .general) {
        registry.register(AppleSystemProvider(source: SystemModelSource()))
        registry.register(classifier: AppleSystemClassifier(useCase: classifierUseCase))
    }

    public static func makeRegistry() -> ProviderRegistry {
        let registry = ProviderRegistry()
        register(in: registry)
        return registry
    }
}
