import Foundation
import MailModel
import OpenHumanAI
import OpenHumanCore

public struct SearchPlanAskPlanner: AskPlanning {
    let source: SearchPlanSource
    let context: @MainActor @Sendable (AccountID) -> SearchInterpretation.Context?
    var resolver: SearchPlanResolver
    var timeout: Duration
    var now: @Sendable () -> Date

    public init(source: SearchPlanSource,
                context: @escaping @MainActor @Sendable (AccountID) -> SearchInterpretation.Context?,
                resolver: SearchPlanResolver = SearchPlanResolver(), timeout: Duration = .seconds(4),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.context = context
        self.resolver = resolver
        self.timeout = timeout
        self.now = now
    }

    public func plan(_ question: String, account: AccountID?) async -> AskPlan? {
        guard let account, await source.isEnabled(), let context = await context(account),
              await source.isModelAvailable(context.accountKey) else { return nil }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let plan = try? await SearchInterpretation.plan(text, accountKey: context.accountKey, source: source,
                                                              timeout: timeout),
              !plan.isEmpty, !Task.isCancelled else { return nil }
        guard let resolved = await resolver.resolve(plan, account: context.account, today: now(),
                                                    contacts: context.contacts, labels: context.labels)
        else { return nil }
        return AskPlan(resolved)
    }

    @MainActor
    public static func live(_ environment: AppEnvironment) -> SearchPlanAskPlanner? {
        guard let source = SearchPlanSource.live(environment) else { return nil }
        let data = environment.data
        return SearchPlanAskPlanner(source: source, context: { [weak environment] account in
            guard let environment, let state = environment.router.accounts.first(where: { $0.id == account }) else {
                return nil
            }
            return SearchInterpretation.Context(
                account: account, accountKey: environment.ai?.policyKey(account), labels: state.labels,
                contacts: { prefix in (try? await data.contactSuggestions(account, prefix: prefix, limit: 5)) ?? [] })
        })
    }
}

extension AskPlan {
    public init(_ resolved: ResolvedSearchPlan) {
        self.init(query: resolved.canonicalText, chips: resolved.chips.map(\.title), semanticText: resolved.semanticText)
    }
}
