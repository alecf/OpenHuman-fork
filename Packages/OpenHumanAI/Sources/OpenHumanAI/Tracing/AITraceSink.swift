import Foundation

public protocol AITraceSink: Sendable {
    func record(_ trace: AITraceRecord) async
    func amend(_ id: UUID, finalText: String?, steps: [AITraceStep]) async
}

public struct AITraceSettings: Sendable, Hashable, Codable {
    public static let defaultKeepDays = 30
    public static let defaultPerFeatureLimit = 500
    public static let defaultMaxBytes = 250_000_000

    public var enabled: Bool
    public var includeText: Bool
    public var keepDays: Int
    public var perFeatureLimit: Int
    public var maxBytes: Int
    public var disabledFeatures: Set<AIFeature>
    public var allowExport: Bool

    public init(enabled: Bool = true, includeText: Bool = true, keepDays: Int = Self.defaultKeepDays,
                perFeatureLimit: Int = Self.defaultPerFeatureLimit, maxBytes: Int = Self.defaultMaxBytes,
                disabledFeatures: Set<AIFeature> = [], allowExport: Bool = false)
    {
        self.enabled = enabled
        self.includeText = includeText
        self.keepDays = keepDays
        self.perFeatureLimit = perFeatureLimit
        self.maxBytes = maxBytes
        self.disabledFeatures = disabledFeatures
        self.allowExport = allowExport
    }

    public func records(_ feature: AIFeature) -> Bool { enabled && !disabledFeatures.contains(feature) }

    public var retention: AITraceRetention {
        AITraceRetention(keepFor: TimeInterval(max(0, keepDays)) * 86_400, perFeature: max(0, perFeatureLimit),
                         maxBytes: max(0, maxBytes))
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, includeText, keepDays, perFeatureLimit, maxBytes, disabledFeatures, allowExport
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AITraceSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        includeText = (try? c.decodeIfPresent(Bool.self, forKey: .includeText)) ?? d.includeText
        keepDays = (try? c.decodeIfPresent(Int.self, forKey: .keepDays)) ?? d.keepDays
        perFeatureLimit = (try? c.decodeIfPresent(Int.self, forKey: .perFeatureLimit)) ?? d.perFeatureLimit
        maxBytes = (try? c.decodeIfPresent(Int.self, forKey: .maxBytes)) ?? d.maxBytes
        disabledFeatures = (try? c.decodeIfPresent(Set<AIFeature>.self, forKey: .disabledFeatures)) ?? d.disabledFeatures
        allowExport = (try? c.decodeIfPresent(Bool.self, forKey: .allowExport)) ?? d.allowExport
    }
}

public struct AITraceRetention: Sendable, Hashable {
    public var keepFor: TimeInterval
    public var perFeature: Int
    public var maxBytes: Int

    public init(keepFor: TimeInterval, perFeature: Int, maxBytes: Int) {
        self.keepFor = keepFor
        self.perFeature = perFeature
        self.maxBytes = maxBytes
    }

    public func survivors(_ traces: [AITraceRecord], now: Date) -> [AITraceRecord] {
        let cutoff = now.addingTimeInterval(-keepFor)
        let newestFirst = traces.filter { $0.createdAt >= cutoff }.sorted { $0.createdAt > $1.createdAt }
        var perFeatureCount: [AIFeature: Int] = [:]
        var kept: [AITraceRecord] = []
        for trace in newestFirst {
            let count = perFeatureCount[trace.feature, default: 0]
            guard count < perFeature else { continue }
            perFeatureCount[trace.feature] = count + 1
            kept.append(trace)
        }
        var total = kept.reduce(0) { $0 + $1.textBytes }
        while total > maxBytes, let oldest = kept.popLast() { total -= oldest.textBytes }
        return kept
    }
}

public struct AITraceQuery: Sendable, Hashable {
    public enum Rating: Sendable, Hashable { case rated, thumbsDown }

    public var features: Set<AIFeature>?
    public var triggers: Set<AITrigger>?
    public var rating: Rating?

    public init(features: Set<AIFeature>? = nil, triggers: Set<AITrigger>? = nil, rating: Rating? = nil) {
        self.features = features
        self.triggers = triggers
        self.rating = rating
    }

    public func matches(_ trace: AITraceRecord) -> Bool {
        if let features, !features.contains(trace.feature) { return false }
        if let triggers, !triggers.contains(trace.trigger) { return false }
        switch rating {
        case nil: return true
        case .rated: return (trace.rating ?? 0) != 0
        case .thumbsDown: return (trace.rating ?? 0) < 0
        }
    }
}

public protocol AITraceStore: Sendable {
    func append(_ trace: AITraceRecord, retention: AITraceRetention, now: Date) async throws
    func amend(_ id: UUID, finalText: String?, steps: [AITraceStep]) async throws
    func setRating(_ id: UUID, rating: Int?) async throws
    func recent(limit: Int) async throws -> [AITraceRecord]
    func traces(matching query: AITraceQuery, limit: Int) async throws -> [AITraceRecord]
    func trace(_ id: UUID) async throws -> AITraceRecord?
    func delete(_ id: UUID) async throws
    func deleteAll() async throws
    func forget(accountKey: String) async throws
}

public struct StoreTraceSink: AITraceSink {
    let store: any AITraceStore
    let settings: @Sendable () async -> AITraceSettings
    let now: @Sendable () -> Date

    public init(store: any AITraceStore, settings: @escaping @Sendable () async -> AITraceSettings,
                now: @escaping @Sendable () -> Date = { Date() })
    {
        self.store = store
        self.settings = settings
        self.now = now
    }

    public func record(_ trace: AITraceRecord) async {
        let current = await settings()
        guard current.records(trace.feature) else { return }
        var kept = trace
        if !current.includeText { kept.removeText() }
        try? await store.append(kept, retention: current.retention, now: now())
    }

    public func amend(_ id: UUID, finalText: String?, steps: [AITraceStep]) async {
        let current = await settings()
        guard current.enabled else { return }
        try? await store.amend(id, finalText: current.includeText ? finalText : nil, steps: steps)
    }
}

public actor InMemoryAITraceStore: AITraceStore {
    private var traces: [AITraceRecord] = []

    public init(_ traces: [AITraceRecord] = []) {
        self.traces = traces.sorted { $0.createdAt > $1.createdAt }
    }

    public func append(_ trace: AITraceRecord, retention: AITraceRetention, now: Date) async throws {
        traces.removeAll { $0.id == trace.id }
        traces.append(trace)
        traces = retention.survivors(traces, now: now)
    }

    public func amend(_ id: UUID, finalText: String?, steps: [AITraceStep]) async throws {
        guard let index = traces.firstIndex(where: { $0.id == id }) else { return }
        if let finalText { traces[index].finalText = finalText }
        traces[index].steps += steps
    }

    public func setRating(_ id: UUID, rating: Int?) async throws {
        guard let index = traces.firstIndex(where: { $0.id == id }) else { return }
        traces[index].rating = rating
    }

    public func recent(limit: Int) async throws -> [AITraceRecord] {
        Array(traces.sorted { $0.createdAt > $1.createdAt }.prefix(max(0, limit)))
    }

    public func traces(matching query: AITraceQuery, limit: Int) async throws -> [AITraceRecord] {
        Array(traces.sorted { $0.createdAt > $1.createdAt }.filter(query.matches).prefix(max(0, limit)))
    }

    public func trace(_ id: UUID) async throws -> AITraceRecord? { traces.first { $0.id == id } }

    public func delete(_ id: UUID) async throws { traces.removeAll { $0.id == id } }

    public func deleteAll() async throws { traces.removeAll() }

    public func forget(accountKey: String) async throws { traces.removeAll { $0.accountKeys.contains(accountKey) } }
}
