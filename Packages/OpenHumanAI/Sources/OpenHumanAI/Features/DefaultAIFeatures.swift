import Foundation

public final class DefaultAIFeatures: AIFeatures {
    let registry: ProviderRegistry
    let settingsSource: @Sendable () async -> AISettings
    let cache: any AIResultCache
    let promptSource: any PromptLibrarySource
    let activity: (any AIActivitySink)?
    let now: @Sendable () -> Date
    let makeNonce: @Sendable () -> String

    public init(
        registry: ProviderRegistry,
        settings: @escaping @Sendable () async -> AISettings,
        cache: any AIResultCache = InMemoryAIResultCache(),
        prompts: any PromptLibrarySource = PromptLibraryProvider.shared,
        activity: (any AIActivitySink)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        makeNonce: @escaping @Sendable () -> String = { Untrusted.makeNonce() }
    ) {
        self.registry = registry
        self.settingsSource = settings
        self.cache = cache
        self.promptSource = prompts
        self.activity = activity
        self.now = now
        self.makeNonce = makeNonce
    }

    var prompts: PromptLibrary { promptSource.current }

    public func status(for feature: AIFeature, accountKey: String?) async -> FeatureStatus {
        let settings = await settingsSource()
        let workload = ProviderSelectionPolicy.workload(for: feature, trigger: .user)
        let candidates = await registry.candidates(for: feature, settings: settings)
        switch ProviderSelectionPolicy.select(
            feature: feature, workload: workload, accountKeys: [accountKey], candidates: candidates, settings: settings)
        {
        case .selected(let candidate):
            return FeatureStatus(
                feature: feature, availability: .available, providerID: candidate.id,
                providerName: candidate.displayName, dataLocation: candidate.dataLocation)
        case .unavailable(let reason, let providerID):
            let candidate = candidates.first { $0.id == providerID }
            return FeatureStatus(
                feature: feature, availability: .unavailable(reason: reason), providerID: providerID,
                providerName: candidate?.displayName, dataLocation: candidate?.dataLocation)
        }
    }
}

struct Engine: Sendable {
    let provider: any AIProvider
    let capabilities: AICapabilities
    let modelVersion: String?
    let settings: AISettings
    let feature: AIFeature
    let workload: AIWorkload
    let threadKey: String?

    var provenance: AIProvenance {
        AIProvenance(providerID: provider.id, providerName: provider.displayName,
                     dataLocation: capabilities.dataLocation)
    }

    func count(_ text: String) async -> Int { await provider.countTokens(text) }

    func tokens(of parts: [UntrustedPart], nonce: String) async -> Int {
        parts.isEmpty ? 0 : await count(Untrusted.render(parts, nonce: nonce))
    }

    func ttl(_ base: Duration?) -> Duration? {
        capabilities.dataLocation == .appleCloud ? min(base ?? AIPolicy.appleCloudTTL, AIPolicy.appleCloudTTL) : base
    }
}

enum Resolution: Sendable {
    case model(Engine)
    case classifier(any AIClassificationProvider)
}

struct PreparedRequest: Sendable {
    var request: AIRequest
    var promptDigest: String
    var fixedTokens: Int
    var budget: Int
}

struct RunOutcome: Sendable {
    var text: String
    var structured: Data?
    var usage: AIUsage?
    var model: String?
}

extension DefaultAIFeatures {
    func resolve(_ feature: AIFeature, trigger: AITrigger, accountKeys: [String?], threadKey: String?) async throws
        -> Resolution
    {
        let settings = await settingsSource()
        let workload = ProviderSelectionPolicy.workload(for: feature, trigger: trigger)
        let candidates = await registry.candidates(for: feature, settings: settings)
        let selection = ProviderSelectionPolicy.select(
            feature: feature, workload: workload, accountKeys: accountKeys, candidates: candidates, settings: settings)
        guard case .selected(let candidate) = selection else {
            if case .unavailable(let reason, _) = selection { throw AIError.unavailable(reason) }
            throw AIError.unavailable(.other("No AI provider is set up"))
        }
        let mustStayOnDevice = workload == .background || settings.requiresOnDevice(accountKeys: accountKeys)
        switch candidate.kind {
        case .classifier:
            guard let classifier = registry.classifier(candidate.id) else {
                throw AIError.unavailable(.other("provider removed"))
            }
            if mustStayOnDevice, classifier.dataLocation.leavesDevice { throw AIError.unavailable(.onDeviceOnly) }
            return .classifier(classifier)
        case .languageModel:
            guard let provider = registry.provider(candidate.id) else {
                throw AIError.unavailable(.other("provider removed"))
            }
            let capabilities = await provider.capabilities()
            if mustStayOnDevice, capabilities.dataLeavesDevice { throw AIError.unavailable(.onDeviceOnly) }
            return .model(
                Engine(
                    provider: provider, capabilities: capabilities, modelVersion: await provider.modelVersion(),
                    settings: settings, feature: feature, workload: workload, threadKey: threadKey))
        }
    }

    func resolveModel(_ feature: AIFeature, trigger: AITrigger, accountKeys: [String?], threadKey: String?)
        async throws -> Engine
    {
        switch try await resolve(feature, trigger: trigger, accountKeys: accountKeys, threadKey: threadKey) {
        case .model(let engine): return engine
        case .classifier: throw AIError.unavailable(.other("not a language model"))
        }
    }

    func prepare(
        _ name: PromptName, engine: Engine, nonce: String, trusted: [TrustedPart], untrusted: [UntrustedPart],
        output: OutputSpec, shrink: Double
    ) async throws -> PreparedRequest {
        let rendered: RenderedPrompt
        do {
            let library = prompts
            rendered = try library.system(
                name, values: ["nonce": nonce, "languageRule": library.languageRule(engine.settings.outputLanguage)])
        } catch {
            throw AIError.providerFailed("prompt \(name.rawValue) unavailable")
        }
        let request = AIRequest(
            task: name.task, promptID: rendered.id, system: rendered.text, trusted: trusted, untrusted: untrusted,
            output: output, nonce: nonce)
        let fixed = await engine.count(rendered.text)
            + (trusted.isEmpty ? 0 : await engine.count(Untrusted.renderTrusted(trusted, nonce: nonce)))
        let budget = try ContextBudgeter.inputBudget(
            engine.capabilities, fixedTokens: fixed, reservedOutput: output.maxTokens, shrink: shrink)
        return PreparedRequest(request: request, promptDigest: rendered.digest, fixedTokens: fixed, budget: budget)
    }

    func requireFits(_ prepared: PreparedRequest, engine: Engine) async throws -> Int {
        let used = await engine.tokens(of: prepared.request.untrusted, nonce: prepared.request.nonce)
        guard used <= prepared.budget else { throw AIError.contextOverflow(counted: used, limit: prepared.budget) }
        return used
    }

    func cacheKey(_ prepared: PreparedRequest, engine: Engine, extra: [String] = []) -> AICacheKey? {
        guard let modelVersion = engine.modelVersion else { return nil }
        return AICacheKey(
            providerID: engine.provider.id, modelVersion: modelVersion, promptID: prepared.request.promptID,
            promptDigest: prepared.promptDigest, task: prepared.request.task,
            inputsDigest: Digest.inputs(of: prepared.request, extra: extra), threadKey: engine.threadKey)
    }

    func cachedResult(_ payload: CachedAIResult.Payload, engine: Engine, model: String?) -> CachedAIResult {
        CachedAIResult(
            payload: payload, providerID: engine.provider.id, providerName: engine.provider.displayName,
            dataLocation: engine.capabilities.dataLocation, model: model, createdAt: now())
    }

    func run(
        _ prepared: PreparedRequest, engine: Engine, untrustedTokens: Int,
        onText: (String) throws -> Bool = { _ in true }
    ) async throws -> RunOutcome {
        let request = prepared.request
        var outcome = RunOutcome(text: "", structured: nil, usage: nil, model: nil)
        var gate: SecretGate? = {
            if case .thirdParty = engine.capabilities.dataLocation { return SecretGate(request: request) }
            return nil
        }()
        var stopped = false
        do {
            events: for try await event in engine.provider.run(request) {
                try Task.checkCancellation()
                switch event {
                case .started(_, let model):
                    outcome.model = model
                case .textDelta(let delta):
                    outcome.text += delta
                    guard outcome.text.utf8.count <= AIPolicy.outputByteCap else {
                        throw AIError.invalidOutput("output too long")
                    }
                    let ready = try gate?.feed(delta) ?? delta
                    if !ready.isEmpty, !(try onText(ready)) {
                        stopped = true
                        break events
                    }
                case .structured(let data):
                    guard data.count <= AIPolicy.outputByteCap else { throw AIError.invalidOutput("output too long") }
                    outcome.structured = data
                case .finished(let usage):
                    outcome.usage = usage
                }
            }
            if !stopped, var finalGate = gate {
                let rest = try finalGate.finish()
                gate = finalGate
                if !rest.isEmpty { _ = try onText(rest) }
            }
            if gate != nil, let structured = outcome.structured {
                try OutputGuard.requireNoSecrets(String(decoding: structured, as: UTF8.self), request: request)
            }
        } catch {
            await record(prepared, engine: engine, untrustedTokens: untrustedTokens, usage: outcome.usage,
                         outcome: Self.activityOutcome(error))
            throw Self.normalized(error)
        }
        await record(prepared, engine: engine, untrustedTokens: untrustedTokens, usage: outcome.usage,
                     outcome: .completed)
        return outcome
    }

    func record(
        _ prepared: PreparedRequest, engine: Engine, untrustedTokens: Int, usage: AIUsage?,
        outcome: AIActivityRecord.Outcome
    ) async {
        guard let activity else { return }
        await activity.record(
            AIActivityRecord(
                date: now(), feature: engine.feature, task: prepared.request.task, providerID: engine.provider.id,
                dataLocation: engine.capabilities.dataLocation, threadKey: engine.threadKey,
                countedInputTokens: prepared.fixedTokens + untrustedTokens, inputBudget: prepared.budget,
                contextTokens: engine.capabilities.contextTokens, usage: usage, outcome: outcome))
    }

    static func activityOutcome(_ error: any Error) -> AIActivityRecord.Outcome {
        switch normalized(error) {
        case AIError.cancelled: return .cancelled
        case let error as AIError: return .failed(String(describing: error))
        default: return .failed("error")
        }
    }

    static func normalized(_ error: any Error) -> any Error {
        if error is CancellationError { return AIError.cancelled }
        if error is AIError { return error }
        return AIError.providerFailed(String(describing: type(of: error)))
    }

    func withOverflowRetry<T>(emitted: () -> Bool = { false }, _ body: (Double) async throws -> T) async throws -> T {
        do {
            return try await body(1)
        } catch AIError.contextOverflow(let counted, let limit) {
            if emitted() { throw AIError.contextOverflow(counted: counted, limit: limit) }
            return try await body(AIPolicy.overflowShrinkFactor)
        }
    }

    func eventStream<Event: Sendable>(
        _ body: @escaping @Sendable (AsyncThrowingStream<Event, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalized(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func subjectPart(_ thread: AIThreadInput) -> UntrustedPart {
        UntrustedPart(kind: .subject, id: thread.threadKey, text: String(thread.subject.prefix(AIPolicy.subjectCharacterCap)))
    }

    func senderPart(_ message: AIMessageInput) -> UntrustedPart {
        UntrustedPart(kind: .sender, id: message.messageKey, text: String(message.from.prefix(AIPolicy.senderCharacterCap)))
    }

    func bodyPart(_ message: AIMessageInput, text: String) -> UntrustedPart {
        UntrustedPart(kind: .emailBody, id: message.messageKey, text: text, date: message.date)
    }

    func cappedBody(_ message: AIMessageInput) -> String {
        guard message.bodyText.count > AIPolicy.messageCharacterCap else { return message.bodyText }
        return String(message.bodyText.prefix(AIPolicy.messageCharacterCap)) + "\n" + AIPolicy.truncationMarker
    }

    func threadParts(_ thread: AIThreadInput) -> [UntrustedPart] {
        [subjectPart(thread)] + thread.messages.flatMap { [senderPart($0), bodyPart($0, text: cappedBody($0))] }
    }

    func today() -> String {
        now().formatted(Date.ISO8601FormatStyle(timeZone: TimeZone.current).year().month().day())
    }
}
