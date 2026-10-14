import Foundation
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore

public struct SearchPlanSource: Sendable {
    public var isEnabled: @MainActor @Sendable () -> Bool
    public var isModelAvailable: @Sendable (_ accountKey: String?) async -> Bool
    public var plan: @Sendable (_ text: String, _ accountKey: String?) async throws -> SearchPlan

    public init(isEnabled: @escaping @MainActor @Sendable () -> Bool,
                isModelAvailable: @escaping @Sendable (_ accountKey: String?) async -> Bool,
                plan: @escaping @Sendable (_ text: String, _ accountKey: String?) async throws -> SearchPlan) {
        self.isEnabled = isEnabled
        self.isModelAvailable = isModelAvailable
        self.plan = plan
    }

    @MainActor
    public static func live(_ environment: AppEnvironment) -> SearchPlanSource? {
        guard let center = environment.ai else { return nil }
        let features = center.features
        return SearchPlanSource(
            isEnabled: { [weak environment, weak center] in
                guard let environment, let center else { return false }
                return environment.modules.modules.contains(.smartSearch) && center.settings.enabled
                    && center.settings.smartSearch.understandSentences
            },
            isModelAvailable: { accountKey in
                await features.status(for: .searchPlan, accountKey: accountKey).availability.isAvailable
            },
            plan: { text, accountKey in try await features.planSearch(text, accountKey: accountKey).plan })
    }
}

extension AICenter {
    public var understandsSearchSentences: Bool { settings.smartSearch.understandSentences }

    public func setUnderstandsSearchSentences(_ on: Bool) {
        try? update { $0.smartSearch.understandSentences = on }
    }
}

@MainActor @Observable
public final class SearchInterpretation {
    public enum State: Hashable, Sendable {
        case hidden
        case waiting
        case ready(ResolvedSearchPlan)
    }

    public struct Context: Sendable {
        public var account: AccountID
        public var accountKey: String?
        public var labels: [LabelInfo]
        public var contacts: @Sendable (String) async -> [EmailAddress]

        public init(account: AccountID, accountKey: String?, labels: [LabelInfo],
                    contacts: @escaping @Sendable (String) async -> [EmailAddress]) {
            self.account = account
            self.accountKey = accountKey
            self.labels = labels
            self.contacts = contacts
        }
    }

    public static let cacheSize = 32

    public private(set) var state: State = .hidden
    @ObservationIgnored public var delay: Duration = .milliseconds(600)
    @ObservationIgnored public var timeout: Duration = .seconds(4)
    @ObservationIgnored public var now: @Sendable () -> Date = { Date() }
    @ObservationIgnored public var resolver = SearchPlanResolver()
    @ObservationIgnored private let source: SearchPlanSource?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var text = ""
    @ObservationIgnored private var dismissedText: String?
    @ObservationIgnored private var cache: [String: ResolvedSearchPlan] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []

    public init(source: SearchPlanSource?) {
        self.source = source
    }

    public var isShowing: Bool { state != .hidden }

    public func textChanged(_ newText: String, context: Context?) {
        task?.cancel()
        task = nil
        text = newText
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source, let context, trimmed != dismissedText, Self.readsAsSentence(trimmed), source.isEnabled() else {
            state = .hidden
            return
        }
        let key = cacheKey(trimmed, context: context)
        if let cached = cache[key] {
            state = .ready(cached)
            return
        }
        state = .hidden
        let delay = self.delay, timeout = self.timeout, resolver = self.resolver, today = now()
        task = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard await source.isModelAvailable(context.accountKey), !Task.isCancelled else { return }
            self?.showWaiting(for: newText)
            let plan = try? await Self.plan(trimmed, accountKey: context.accountKey, source: source, timeout: timeout)
            guard !Task.isCancelled else { return }
            guard let plan, !plan.isEmpty else {
                self?.finish(nil, for: newText, key: key)
                return
            }
            let resolved = await resolver.resolve(plan, account: context.account, today: today,
                                                  contacts: context.contacts, labels: context.labels)
            guard !Task.isCancelled else { return }
            self?.finish(resolved, for: newText, key: key)
        }
    }

    public func accept() -> String? {
        guard case .ready(let resolved) = state else { return nil }
        task?.cancel()
        state = .hidden
        return resolved.canonicalText
    }

    public func dismiss() {
        task?.cancel()
        dismissedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .hidden
    }

    public func reset() {
        task?.cancel()
        task = nil
        dismissedText = nil
        state = .hidden
    }

    private func showWaiting(for requested: String) {
        guard requested == text else { return }
        state = .waiting
    }

    private func finish(_ resolved: ResolvedSearchPlan?, for requested: String, key: String) {
        guard requested == text else { return }
        if let resolved { remember(resolved, key: key) }
        state = resolved.map(State.ready) ?? .hidden
    }

    private func remember(_ resolved: ResolvedSearchPlan, key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = resolved
        while cacheOrder.count > Self.cacheSize { cache[cacheOrder.removeFirst()] = nil }
    }

    private func cacheKey(_ text: String, context: Context) -> String {
        let day = now().formatted(Date.ISO8601FormatStyle(timeZone: resolver.calendar.timeZone).year().month().day())
        return "\(context.account.rawValue)|\(day)|\(text)"
    }

    nonisolated static func plan(_ text: String, accountKey: String?, source: SearchPlanSource,
                                 timeout: Duration) async throws -> SearchPlan? {
        try await withThrowingTaskGroup(of: SearchPlan?.self) { group in
            group.addTask { try await source.plan(text, accountKey) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    public static let cueWords: Set<String> = [
        "today", "yesterday", "last", "this", "past", "ago", "since", "before", "after", "week", "weeks", "month",
        "months", "year", "years", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december", "from", "to", "with", "by", "sent", "wrote", "emailed", "attachment", "attachments",
        "attached", "pdf", "pdfs", "spreadsheet", "spreadsheets", "invite", "invites", "unread", "starred",
    ]

    public static func readsAsSentence(_ text: String) -> Bool {
        guard !text.contains("\"") else { return false }
        let tokens = SearchSyntax.tokens(text)
        guard tokens.count >= 3 else { return false }
        let operatorLike = tokens.contains { token in
            token.isChip || token.text.hasPrefix("-") || token.text.contains(":") || token.text.hasPrefix("(")
                || token.text.hasPrefix("{")
        }
        guard !operatorLike else { return false }
        if tokens.count >= 5 { return true }
        return tokens.contains { cueWords.contains($0.text.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
    }
}
