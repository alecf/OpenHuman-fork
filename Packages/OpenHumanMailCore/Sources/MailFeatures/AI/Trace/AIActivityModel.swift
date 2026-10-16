import Foundation
import Observation
import OpenHumanAI

@MainActor @Observable
public final class AIActivityModel {
    public enum Page: String, CaseIterable, Sendable {
        case requests, feedback

        public var title: String {
            switch self {
            case .requests: String(localized: "Requests")
            case .feedback: String(localized: "Feedback")
            }
        }
    }

    public enum Filter: String, CaseIterable, Sendable {
        case askedFor, commandJ, quickReplies, summaries, background, all

        public var title: String {
            switch self {
            case .askedFor: String(localized: "You asked for")
            case .commandJ: String(localized: "⌘J and Ask AI")
            case .quickReplies: String(localized: "Quick replies")
            case .summaries: String(localized: "Summaries")
            case .background: String(localized: "Background")
            case .all: String(localized: "All requests")
            }
        }

        public var query: AITraceQuery {
            switch self {
            case .askedFor: AITraceQuery(triggers: [.user])
            case .commandJ: AITraceQuery(features: [.rewrite, .askInbox])
            case .quickReplies: AITraceQuery(features: [.replyOptions])
            case .summaries: AITraceQuery(features: [.summarize])
            case .background: AITraceQuery(triggers: [.automatic])
            case .all: AITraceQuery()
            }
        }
    }

    public struct Row: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let date: Date
        public let feature: String
        public let model: String
        public let numbers: String
        public let snippet: String?
        public let badge: AIProviderBadge
        public let cacheHit: Bool
        public let failed: Bool
        public let rating: Int?
    }

    public static let displayLimit = 200
    public static let keepDaysChoices = [1, 7, 30, 90, 365]
    public static let perFeatureChoices = [100, 500, 1_000, 5_000]
    public static let sizeChoices = [50_000_000, 250_000_000, 1_000_000_000]

    public let center: AICenter
    public var page: Page = .requests
    public var filter: Filter = .askedFor
    public var onlyThumbsDown = false
    public private(set) var traces: [AITraceRecord] = []
    public private(set) var hasMore = false
    public private(set) var keepsAny = false
    public private(set) var detail: AITraceDetail?
    public private(set) var error: String?

    public init(center: AICenter) {
        self.center = center
    }

    public var isAvailable: Bool { center.traces != nil }

    public var query: AITraceQuery {
        switch page {
        case .requests: filter.query
        case .feedback: AITraceQuery(rating: onlyThumbsDown ? .thumbsDown : .rated)
        }
    }

    public var reloadKey: String { "\(page.rawValue).\(filter.rawValue).\(onlyThumbsDown)" }

    public var rows: [Row] { traces.map(Self.row) }

    public var showsSnippets: Bool { page == .feedback }

    public var emptyText: String {
        switch page {
        case .requests:
            switch filter {
            case .askedFor: String(localized: "Nothing you asked AI for yet. Requests Mail makes on its own are under Background.")
            case .all: String(localized: "No AI requests yet.")
            default: String(localized: "Nothing under \(filter.title) yet.")
            }
        case .feedback: onlyThumbsDown ? String(localized: "No answers rated thumbs down.")
            : String(localized: "No rated answers yet. Rate a ⌘J answer with thumbs up or down.")
        }
    }

    public var summary: String {
        let count = hasMore ? String(localized: "Newest \(Self.displayLimit) shown")
            : page == .feedback ? String(localized: "\(traces.count) rated") : String(localized: "\(traces.count) requests")
        let left = traces.filter(\.leftDevice).count
        return count + " · " + (left == 0 ? String(localized: "none left this Mac") : String(localized: "\(left) left this Mac"))
    }

    static func row(_ trace: AITraceRecord) -> Row {
        var numbers: [String] = []
        if let tokens = AITraceWording.tokens(trace) { numbers.append(tokens) }
        if let latency = trace.latencyMilliseconds { numbers.append(AITraceWording.duration(milliseconds: latency)) }
        if trace.outcome == .cancelled { numbers.append(AITraceWording.outcome(trace)) }
        var badge = AIProviderBadge(providerName: trace.providerName, location: trace.dataLocation,
                                    fromCache: trace.cache == .hit)
        badge.traceID = trace.id
        return Row(id: trace.id, date: trace.createdAt, feature: AITraceWording.title(trace),
                   model: AITraceWording.model(trace), numbers: numbers.joined(separator: " · "),
                   snippet: AITraceWording.snippet(trace), badge: badge, cacheHit: trace.cache == .hit,
                   failed: trace.outcome == .failed, rating: trace.rating)
    }

    public func refresh() async {
        guard let store = center.traces else {
            traces = []
            hasMore = false
            keepsAny = false
            return
        }
        do {
            let found = try await store.traces(matching: query, limit: Self.displayLimit + 1)
            traces = Array(found.prefix(Self.displayLimit))
            hasMore = found.count > Self.displayLimit
            if found.isEmpty {
                keepsAny = !(try await store.recent(limit: 1)).isEmpty
            } else {
                keepsAny = true
            }
            error = nil
        } catch {
            self.error = Self.loadFailure
        }
    }

    public func open(_ id: UUID) async {
        guard let store = center.traces, let trace = try? await store.trace(id) else {
            detail = nil
            error = Self.loadFailure
            return
        }
        let why = await center.whyLine(for: trace)
        detail = AITraceDetail(trace, why: why)
        error = nil
    }

    public func closeDetail() {
        detail = nil
    }

    public var backTitle: String {
        page == .feedback ? Page.feedback.title : filter.title
    }

    public func delete(_ id: UUID) async {
        try? await center.traces?.delete(id)
        if detail?.id == id { detail = nil }
        await refresh()
    }

    public func clearAll() async {
        try? await center.traces?.deleteAll()
        detail = nil
        await refresh()
    }

    public func clearCache() async {
        await center.clearCache()
    }

    public var keepsTraces: Bool {
        get { center.settings.traces.enabled }
        set { change { $0.traces.enabled = newValue } }
    }

    public var keepDays: Int {
        get { center.settings.traces.keepDays }
        set { change { $0.traces.keepDays = max(1, newValue) } }
    }

    public var perFeatureLimit: Int {
        get { center.settings.traces.perFeatureLimit }
        set { change { $0.traces.perFeatureLimit = max(1, newValue) } }
    }

    public var maxBytes: Int {
        get { center.settings.traces.maxBytes }
        set { change { $0.traces.maxBytes = max(1_000_000, newValue) } }
    }

    public func keeps(_ feature: AIFeature) -> Bool {
        !center.settings.traces.disabledFeatures.contains(feature)
    }

    public func setKeeps(_ feature: AIFeature, _ on: Bool) {
        change { settings in
            if on { settings.traces.disabledFeatures.remove(feature) } else { settings.traces.disabledFeatures.insert(feature) }
        }
    }

    public static func days(_ days: Int) -> String {
        switch days {
        case 1: String(localized: "1 day")
        case 365: String(localized: "1 year")
        default: String(localized: "\(days) days")
        }
    }

    public static func size(_ bytes: Int) -> String {
        bytes >= 1_000_000_000 ? String(localized: "\(bytes / 1_000_000_000) GB")
            : String(localized: "\(bytes / 1_000_000) MB")
    }

    public static let note = String(localized: "Each trace keeps the prompt, the email text sent and the answer. Traces stay on this Mac and are never sent anywhere.")
    public static let retentionNote = String(localized: "Older traces are removed when a new one is saved.")
    public static let cacheTitle = String(localized: "Saved answers")
    public static let cacheDetail = String(localized: "Summaries and replies Mail keeps so it doesn't ask the model twice. Clearing them makes the next ones be written again. Traces stay.")
    public static let clearConfirmTitle = String(localized: "Clear all AI traces?")
    public static let clearConfirmDetail = String(localized: "This deletes every trace and rating on this Mac. It can't be undone.")
    static let loadFailure = String(localized: "Couldn't read the AI traces")
    static let saveFailure = String(localized: "Couldn't save the AI setting")

    private func change(_ mutate: (inout AISettings) -> Void) {
        do {
            try center.update(mutate)
            error = nil
        } catch {
            self.error = Self.saveFailure
        }
    }
}
