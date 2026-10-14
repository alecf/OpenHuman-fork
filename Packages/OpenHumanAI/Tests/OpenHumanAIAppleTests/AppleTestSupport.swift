import Foundation

@testable import OpenHumanAI

func makeFeatures(_ providers: [any AIProvider], settings: AISettings = AISettings()) -> DefaultAIFeatures {
    DefaultAIFeatures(
        registry: ProviderRegistry(providers: providers), settings: { settings }, cache: InMemoryAIResultCache(),
        activity: nil, now: { Date(timeIntervalSince1970: 1_790_100_000) })
}

func aiError(_ body: () async throws -> Void) async -> AIError? {
    do {
        try await body()
        return nil
    } catch let error as AIError {
        return error
    } catch {
        return .providerFailed("non-AIError \(error)")
    }
}
