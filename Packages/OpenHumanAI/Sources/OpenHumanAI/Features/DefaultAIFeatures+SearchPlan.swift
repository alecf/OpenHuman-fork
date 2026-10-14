import Foundation

extension DefaultAIFeatures {
    public func planSearch(_ text: String, accountKey: String?) async throws -> SearchPlanResult {
        let question = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AIPolicy.searchQuestionCharacterCap))
        guard !question.isEmpty else { throw AIError.invalidOutput("empty search") }
        let engine = try await resolveModel(.searchPlan, trigger: .user, accountKeys: [accountKey], threadKey: nil)
        guard engine.capabilities.dataLocation == .onDevice else { throw AIError.unavailable(.onDeviceOnly) }
        let trusted = [
            TrustedPart(kind: .userQuestion, text: question),
            TrustedPart(kind: .today, text: searchToday()),
        ]
        let output = OutputSpec.json(schema: OutputGuard.searchPlanSchema, maxTokens: AIPolicy.reservedSearchPlanTokens)
        let nonce = makeNonce()
        let prepared = try await prepare(.searchPlan, engine: engine, nonce: nonce, trusted: trusted, untrusted: [],
                                         output: output, shrink: 1)
        let used = try await requireFits(prepared, engine: engine)
        let (plan, outcome, raw) = try await structuredAnswer(prepared, engine: engine, untrustedTokens: used) {
            try OutputGuard.searchPlan(from: $0)
        }
        var provenance = engine.provenance
        provenance.model = outcome.model
        return SearchPlanResult(
            plan: plan, provenance: provenance,
            report: AIOutputReport(suspicious: OutputGuard.isSuspicious(raw, nonce: nonce), usage: outcome.usage))
    }

    func searchToday() -> String {
        let zone = TimeZone.current
        let date = now()
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: zone).year().month().day())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let weekday = calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
        return "\(day), \(weekday), \(zone.identifier)"
    }
}
