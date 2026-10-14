import Foundation
import Synchronization
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

let fixedNow = Date(timeIntervalSince1970: 1_790_100_000)

func collect<Event>(_ stream: AsyncThrowingStream<Event, Error>) async throws -> [Event] {
    var events: [Event] = []
    for try await event in stream { events.append(event) }
    return events
}

func makeFeatures(
    _ providers: [any AIProvider], classifiers: [any AIClassificationProvider] = [], settings: AISettings = AISettings(),
    cache: any AIResultCache = InMemoryAIResultCache(), activity: (any AIActivitySink)? = nil,
    now: @escaping @Sendable () -> Date = { fixedNow }
) -> DefaultAIFeatures {
    DefaultAIFeatures(
        registry: ProviderRegistry(providers: providers, classifiers: classifiers), settings: { settings },
        cache: cache, activity: activity, now: now)
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

func independentBudget(_ request: AIRequest, capabilities: AICapabilities) throws -> Int {
    try ContextBudgeter.inputBudget(capabilities, fixedTokens: fixedTokens(request), reservedOutput: request.output.maxTokens)
}

func fixedTokens(_ request: AIRequest) -> Int {
    TokenHeuristic.count(request.system)
        + (request.trusted.isEmpty ? 0 : TokenHeuristic.count(Untrusted.renderTrusted(request.trusted, nonce: request.nonce)))
}

func untrustedTokens(_ request: AIRequest) -> Int {
    request.untrusted.isEmpty ? 0 : TokenHeuristic.count(Untrusted.render(request.untrusted, nonce: request.nonce))
}

func summaryText(_ events: [SummaryEvent]) -> String {
    events.compactMap { if case .textDelta(let text) = $0 { return text } else { return nil } }.joined()
}

func summaryReport(_ events: [SummaryEvent]) -> AIOutputReport? {
    for case .completed(let report) in events { return report }
    return nil
}

func summaryProvenance(_ events: [SummaryEvent]) -> AIProvenance? {
    for case .started(let provenance) in events { return provenance }
    return nil
}

let replyJSON =
    #"{"options":[{"label":"Yes","body":"Yes, that works for me."},{"label":"No","body":"Sorry, I can't."},"#
    + #"{"label":"Question","body":"What time works best?"}]}"#

func remoteCapabilities(contextTokens: Int? = nil, cap: Int? = 32_000, vendor: String = "Anthropic via Claude Code")
    -> AICapabilities
{
    .fake(contextTokens: contextTokens, policyInputCap: cap, dataLocation: .thirdParty(vendor: vendor))
}

final class RecordingCache: AIResultCache {
    private let base = InMemoryAIResultCache(now: { fixedNow })
    private let stored = Mutex<[AICacheKey]>([])

    var keys: [AICacheKey] { stored.withLock { $0 } }

    func get(_ key: AICacheKey) async -> CachedAIResult? { await base.get(key) }

    func put(_ key: AICacheKey, _ value: CachedAIResult, ttl: Duration?) async {
        stored.withLock { $0.append(key) }
        await base.put(key, value, ttl: ttl)
    }

    func invalidate(threadKey: String) async { await base.invalidate(threadKey: threadKey) }
    func removeAll() async { await base.removeAll() }
}

func consenting(_ ids: [AIProviderID], _ base: AISettings = AISettings()) -> AISettings {
    var settings = base
    for id in ids { settings.consents[id] = ProviderConsent(grantedAt: fixedNow, fingerprint: nil) }
    return settings
}
