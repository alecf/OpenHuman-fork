import Foundation

extension DefaultAIFeatures {
    public func detectFollowUp(_ input: FollowUpInput) async throws -> FollowUpResult {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .no }
        let engine = try await resolveModel(.followUp, trigger: .automatic, accountKeys: [input.accountKey],
                                            threadKey: input.threadKey)
        guard engine.capabilities.dataLocation == .onDevice else { throw AIError.unavailable(.onDeviceOnly) }
        let key = followUpCacheKey(input, engine: engine)
        if let key, let hit = await cache.get(key), case .json(let data) = hit.payload,
           var cached = try? JSONDecoder().decode(FollowUpResult.self, from: data) {
            cached.fromCache = true
            return cached
        }
        let output = OutputSpec.json(schema: OutputGuard.followUpSchema, maxTokens: AIPolicy.reservedFollowUpTokens)
        let subject = UntrustedPart(kind: .subject, id: input.threadKey ?? input.messageKey,
                                    text: String(input.subject.prefix(AIPolicy.subjectCharacterCap)))
        let sent = [
            UntrustedPart(kind: .sender, id: input.messageKey, text: String(input.from.prefix(AIPolicy.senderCharacterCap))),
            UntrustedPart(kind: .emailBody, id: input.messageKey,
                          text: Self.followUpCapped(text, AIPolicy.followUpMessageCharacters), date: input.sentAt),
        ]
        let context = input.context.suffix(AIPolicy.followUpContextMessages).flatMap { message in
            [senderPart(message),
             bodyPart(message, text: Self.followUpCapped(message.bodyText, AIPolicy.followUpContextCharacters))]
        }
        return try await withOverflowRetry { shrink in
            let nonce = makeNonce()
            var prepared = try await prepare(.followUp, engine: engine, nonce: nonce, trusted: [],
                                             untrusted: [subject] + context + sent, output: output, shrink: shrink)
            var kept = context
            while !kept.isEmpty, await engine.tokens(of: prepared.request.untrusted, nonce: nonce) > prepared.budget {
                kept.removeFirst(min(2, kept.count))
                prepared.request.untrusted = [subject] + kept + sent
            }
            if await engine.tokens(of: prepared.request.untrusted, nonce: nonce) > prepared.budget {
                let head = [subject, sent[0]]
                let body = sent[1]
                let budget = prepared.budget
                let cut = try await Chunker.truncate(body.text) { candidate in
                    let part = UntrustedPart(kind: body.kind, id: body.id, text: candidate, date: body.date)
                    return await engine.tokens(of: head + [part], nonce: nonce) <= budget
                }
                prepared.request.untrusted = head + [UntrustedPart(kind: body.kind, id: body.id, text: cut, date: body.date)]
            }
            let used = try await requireFits(prepared, engine: engine)
            let (answer, outcome, raw) = try await structuredAnswer(prepared, engine: engine, untrustedTokens: used) {
                try OutputGuard.followUp(from: $0)
            }
            if OutputGuard.isSuspicious(raw, nonce: nonce) {
                return FollowUpResult(needsFollowUp: false, reason: "", providerID: engine.provider.id)
            }
            var result = answer
            result.providerID = engine.provider.id
            if let key, let data = try? JSONEncoder().encode(result) {
                await cache.put(key, cachedResult(.json(data), engine: engine, model: outcome.model), ttl: engine.ttl(nil))
            }
            return result
        }
    }

    func followUpCacheKey(_ input: FollowUpInput, engine: Engine) -> AICacheKey? {
        guard let modelVersion = engine.modelVersion,
              let template = try? prompts.template(named: PromptName.followUp.rawValue),
              let digest = try? prompts.digest(.followUp) else { return nil }
        return AICacheKey(providerID: engine.provider.id, modelVersion: modelVersion, promptID: template.id,
                          promptDigest: digest, task: .followUp,
                          inputsDigest: Digest.sha256Hex(["followUp.message", input.messageKey]),
                          threadKey: input.threadKey)
    }

    static func followUpCapped(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n" + AIPolicy.truncationMarker
    }
}
