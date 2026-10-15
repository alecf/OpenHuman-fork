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

    public struct Row: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let date: Date
        public let feature: String
        public let model: String
        public let numbers: String
        public let badge: AIProviderBadge
        public let cacheHit: Bool
        public let failed: Bool
        public let rating: Int?
    }

    public static let loadLimit = 2_000
    public static let displayLimit = 200
    public static let keepDaysChoices = [1, 7, 30, 90, 365]
    public static let perFeatureChoices = [100, 500, 1_000, 5_000]
    public static let sizeChoices = [50_000_000, 250_000_000, 1_000_000_000]

    public let center: AICenter
    public var page: Page = .requests
    public var onlyThumbsDown = false
    public private(set) var traces: [AITraceRecord] = []
    public private(set) var detail: AITraceDetail?
    public private(set) var error: String?

    public init(center: AICenter) {
        self.center = center
    }

    public var isAvailable: Bool { center.traces != nil }

    public var rows: [Row] {
        let shown = switch page {
        case .requests: traces
        case .feedback: traces.filter { trace in
            guard let rating = trace.rating, rating != 0 else { return false }
            return !onlyThumbsDown || rating < 0
        }
        }
        return shown.prefix(Self.displayLimit).map(Self.row)
    }

    public var emptyText: String {
        switch page {
        case .requests: String(localized: "No AI requests yet.")
        case .feedback: onlyThumbsDown ? String(localized: "No answers rated thumbs down.")
            : String(localized: "No rated answers yet. Rate a ⌘J answer with thumbs up or down.")
        }
    }

    public var summary: String {
        let left = traces.filter(\.leftDevice).count
        var parts = [String(localized: "\(traces.count) requests kept")]
        parts.append(left == 0 ? String(localized: "none left this Mac") : String(localized: "\(left) left this Mac"))
        if traces.count > Self.displayLimit { parts.append(String(localized: "newest \(Self.displayLimit) shown")) }
        return parts.joined(separator: " · ")
    }

    static func row(_ trace: AITraceRecord) -> Row {
        var numbers: [String] = []
        if let tokens = AITraceWording.tokens(trace) { numbers.append(tokens) }
        if let latency = trace.latencyMilliseconds { numbers.append(AITraceWording.duration(milliseconds: latency)) }
        if trace.outcome != .completed, trace.cache != .hit { numbers.append(AITraceWording.outcome(trace)) }
        var badge = AIProviderBadge(providerName: trace.providerName, location: trace.dataLocation,
                                    fromCache: trace.cache == .hit)
        badge.traceID = trace.id
        return Row(id: trace.id, date: trace.createdAt, feature: AITraceWording.feature(trace.feature),
                   model: AITraceWording.model(trace), numbers: numbers.joined(separator: " · "), badge: badge,
                   cacheHit: trace.cache == .hit, failed: trace.outcome == .failed, rating: trace.rating)
    }

    public func refresh() async {
        guard let store = center.traces else {
            traces = []
            return
        }
        do {
            traces = try await store.recent(limit: Self.loadLimit)
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
