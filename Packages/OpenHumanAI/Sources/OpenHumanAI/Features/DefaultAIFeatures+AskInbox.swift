import Foundation

extension DefaultAIFeatures {
    public func askInbox(_ question: String, candidates: [AIMessageInput]) -> AsyncThrowingStream<AskInboxEvent, Error> {
        eventStream { continuation in
            let candidates = Array(candidates.prefix(AIPolicy.askInboxMaxCandidates))
            let engine = try await self.resolveModel(
                .askInbox, trigger: .user, accountKeys: candidates.map(\.accountKey), threadKey: nil)
            let question = String(question.prefix(AIPolicy.userInstructionCharacterCap))
            let keywords = ExcerptWindow.keywords(in: question)
            let trusted = [
                TrustedPart(kind: .userQuestion, text: question), TrustedPart(kind: .today, text: self.today()),
            ]
            var started = false
            var emitted = false
            try await self.withOverflowRetry(emitted: { emitted }) { shrink in
                let nonce = self.makeNonce()
                var prepared = try await self.prepare(
                    .askInbox, engine: engine, nonce: nonce, trusted: trusted, untrusted: [],
                    output: .text(maxTokens: AIPolicy.reservedAskInboxTokens), shrink: shrink)
                var parts: [UntrustedPart] = []
                var included = Set<String>()
                for candidate in candidates {
                    var candidateParts: [UntrustedPart] = []
                    if let subject = candidate.subject, !subject.isEmpty {
                        candidateParts.append(
                            UntrustedPart(kind: .subject, id: candidate.messageKey,
                                          text: String(subject.prefix(AIPolicy.subjectCharacterCap))))
                    }
                    candidateParts.append(self.senderPart(candidate))
                    candidateParts.append(
                        UntrustedPart(
                            kind: .excerpt, id: candidate.messageKey,
                            text: ExcerptWindow.best(in: candidate.bodyText, keywords: keywords), date: candidate.date))
                    if await engine.tokens(of: parts + candidateParts, nonce: nonce) <= prepared.budget {
                        parts += candidateParts
                        included.insert(candidate.messageKey)
                    }
                }
                if parts.isEmpty, let first = candidates.first {
                    let alone = await engine.tokens(of: [self.senderPart(first)], nonce: nonce)
                    throw AIError.contextOverflow(counted: alone, limit: prepared.budget)
                }
                prepared.request.untrusted = parts
                let used = try await self.requireFits(prepared, engine: engine)
                if !started {
                    continuation.yield(.started(engine.provenance))
                    started = true
                }
                var sources = SourcesLineFilter()
                var capper = StreamCapper(maxTokens: AIPolicy.reservedAskInboxTokens)
                let outcome = try await self.run(prepared, engine: engine, untrustedTokens: used) { delta in
                    let shown = capper.accept(sources.feed(delta))
                    if !shown.isEmpty {
                        emitted = true
                        continuation.yield(.textDelta(shown))
                    }
                    return true
                }
                let tail = capper.accept(sources.finish())
                if !tail.isEmpty { continuation.yield(.textDelta(tail)) }
                continuation.yield(.citations(OutputGuard.filterCitations(sources.cited, allowed: included)))
                continuation.yield(
                    .completed(
                        AIOutputReport(
                            suspicious: OutputGuard.isSuspicious(outcome.text, nonce: nonce),
                            truncated: capper.truncated, usage: outcome.usage)))
            }
        }
    }
}
