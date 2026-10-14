import Foundation

extension DefaultAIFeatures {
    public func classify(_ thread: AIThreadInput) async throws -> TriageResult {
        guard !thread.messages.isEmpty else { throw AIError.unavailable(.other("The thread has no messages")) }
        let input = ClassificationInput.make(from: thread)
        switch try await resolve(.classify, trigger: .automatic, accountKeys: [thread.accountKey], threadKey: thread.threadKey) {
        case .classifier(let classifier):
            return try await classify(input, with: classifier)
        case .model(let engine):
            return try await classify(input, with: engine)
        }
    }

    private func classify(_ input: ClassificationInput, with classifier: any AIClassificationProvider) async throws
        -> TriageResult
    {
        var key: AICacheKey?
        if let version = await classifier.modelVersion() {
            let inputs = Digest.sha256Hex(input.parts.flatMap { [$0.kind.rawValue, $0.id, $0.text] })
            key = AICacheKey(
                providerID: classifier.id, modelVersion: version, promptID: PromptID("classifier", version: 1),
                promptDigest: "", task: .classify, inputsDigest: inputs, threadKey: input.threadKey)
        }
        if let key, let hit = await cache.get(key), case .json(let data) = hit.payload,
            let result = try? JSONDecoder().decode(TriageResult.self, from: data)
        {
            return result
        }
        let raw: TriageResult
        do {
            raw = try await classifier.classify(input)
        } catch {
            throw Self.normalized(error)
        }
        let (result, suspicious) = OutputGuard.checkedTriage(
            TriageResult(category: raw.category, priority: raw.priority, reason: raw.reason, providerID: classifier.id),
            nonce: nil)
        if !suspicious, let key, let data = try? JSONEncoder().encode(result) {
            await cache.put(
                key,
                CachedAIResult(
                    payload: .json(data), providerID: classifier.id, providerName: classifier.displayName,
                    dataLocation: classifier.dataLocation, model: nil, createdAt: now()),
                ttl: nil)
        }
        return result
    }

    private func classify(_ input: ClassificationInput, with engine: Engine) async throws -> TriageResult {
        let output = OutputSpec.json(schema: OutputGuard.triageSchema, maxTokens: AIPolicy.reservedTriageTokens)
        return try await withOverflowRetry { shrink in
            let nonce = makeNonce()
            var prepared = try await prepare(
                .classify, engine: engine, nonce: nonce, trusted: [], untrusted: input.parts, output: output,
                shrink: shrink)
            if await engine.tokens(of: input.parts, nonce: nonce) > prepared.budget {
                let head = [input.subject, input.sender]
                let budget = prepared.budget
                let excerpt = try await Chunker.truncate(input.excerpt.text) { text in
                    let part = UntrustedPart(kind: input.excerpt.kind, id: input.excerpt.id, text: text,
                                             date: input.excerpt.date)
                    return await engine.tokens(of: head + [part], nonce: nonce) <= budget
                }
                prepared.request.untrusted = head + [
                    UntrustedPart(kind: input.excerpt.kind, id: input.excerpt.id, text: excerpt, date: input.excerpt.date)
                ]
            }
            let used = try await requireFits(prepared, engine: engine)
            let key = cacheKey(prepared, engine: engine)
            if let key, let hit = await cache.get(key), case .json(let data) = hit.payload,
                let result = try? JSONDecoder().decode(TriageResult.self, from: data)
            {
                await record(prepared, engine: engine, untrustedTokens: used, usage: nil, outcome: .cached)
                return result
            }
            let ((result, flagged), outcome, raw) = try await structuredAnswer(
                prepared, engine: engine, untrustedTokens: used
            ) {
                try OutputGuard.triage(from: $0, nonce: nonce, providerID: engine.provider.id)
            }
            let suspicious = flagged || OutputGuard.isSuspicious(raw, nonce: nonce)
            let final = suspicious
                ? TriageResult(category: result.category, priority: result.priority, reason: "", providerID: result.providerID)
                : result
            if !suspicious, let key, let data = try? JSONEncoder().encode(final) {
                await cache.put(key, cachedResult(.json(data), engine: engine, model: outcome.model), ttl: engine.ttl(nil))
            }
            return final
        }
    }
}
