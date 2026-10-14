import Foundation

extension DefaultAIFeatures {
    public static let maxStyleExamples = 3
    public static let styleExampleCharacters = 600

    public func rewriteEvents(_ text: String, instruction: String, context: AIThreadInput?)
        -> AsyncThrowingStream<RewriteEvent, Error>
    {
        eventStream { continuation in
            let engine = try await self.resolveModel(
                .rewrite, trigger: .user, accountKeys: [context?.accountKey], threadKey: context?.threadKey)
            let draftTokens = await engine.count(text)
            var summary: UntrustedPart?
            if let context, let key = self.threadSummaryKey(context, engine: engine), let hit = await self.cache.get(key),
                case .text(let text) = hit.payload
            {
                summary = UntrustedPart(kind: .summary, id: context.threadKey, text: text)
            }
            let draft = UntrustedPart(kind: .draft, id: "draft", text: text)
            let preferences = engine.settings.userPreferencesText.map { [TrustedPart(kind: .userPreferences, text: $0)] }
            let trusted = [
                TrustedPart(kind: .userInstruction, text: String(instruction.prefix(AIPolicy.userInstructionCharacterCap)))
            ] + (preferences ?? [])
            let styleParts = Self.styleParts(context?.styleExamples ?? [], dataLocation: engine.capabilities.dataLocation)
            var started = false
            var emitted = false
            try await self.withOverflowRetry(emitted: { emitted }) { shrink in
                let nonce = self.makeNonce()
                let sizing = try await self.prepare(
                    .rewrite, engine: engine, nonce: nonce, trusted: trusted, untrusted: [draft],
                    output: .text(maxTokens: AIPolicy.generationMinimumOutputTokens), shrink: shrink)
                let draftShare = await engine.tokens(of: [draft], nonce: nonce)
                let limit = Int(Double(sizing.budget) * AIPolicy.rewriteSelectionBudgetFraction)
                guard draftShare <= limit else { throw AIError.contextOverflow(counted: draftShare, limit: limit) }
                var parts = [draft]
                if let summary, await engine.tokens(of: [draft, summary], nonce: nonce) <= sizing.budget {
                    parts.append(summary)
                }
                for example in styleParts {
                    if await engine.tokens(of: parts + [example], nonce: nonce) <= sizing.budget { parts.append(example) }
                }
                let inputTokens = sizing.fixedTokens + (await engine.tokens(of: parts, nonce: nonce))
                let output = OutputSpec.text(
                    maxTokens: AIPolicy.generationOutputBudget(
                        contextTokens: engine.capabilities.contextTokens, inputTokens: inputTokens))
                var prepared = try await self.prepare(
                    .rewrite, engine: engine, nonce: nonce, trusted: trusted, untrusted: parts, output: output,
                    shrink: shrink)
                let used = try await self.requireFits(prepared, engine: engine)
                if !started {
                    continuation.yield(.started(engine.provenance))
                    started = true
                }
                var capper = StreamCapper(maxTokens: output.maxTokens)
                let outcome = try await self.run(prepared, engine: engine, untrustedTokens: used) { delta in
                    let shown = capper.accept(delta)
                    if !shown.isEmpty {
                        emitted = true
                        continuation.yield(.textDelta(shown))
                    }
                    return !capper.truncated
                }
                continuation.yield(
                    .completed(
                        AIOutputReport(
                            suspicious: OutputGuard.isSuspicious(outcome.text, nonce: nonce),
                            truncated: capper.truncated, usage: outcome.usage)))
            }
        }
    }

    static func styleParts(_ examples: [String], dataLocation: AIDataLocation) -> [UntrustedPart] {
        guard dataLocation == .onDevice else { return [] }
        let kept = examples.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return kept.prefix(maxStyleExamples).enumerated().map { index, example in
            UntrustedPart(kind: .styleExample, id: "style-\(index + 1)", text: String(example.prefix(styleExampleCharacters)))
        }
    }
}
