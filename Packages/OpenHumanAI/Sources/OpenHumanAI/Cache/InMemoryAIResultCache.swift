import Foundation

public actor InMemoryAIResultCache: AIResultCache {
    private struct Entry {
        var value: CachedAIResult
        var expires: Date?
        var sequence: Int
    }

    public static let defaultCapacity = 2_000
    private var entries: [String: Entry] = [:]
    private var threadIndex: [String: Set<String>] = [:]
    private var sequence = 0
    private let capacity: Int
    private let now: @Sendable () -> Date

    public init(capacity: Int = InMemoryAIResultCache.defaultCapacity, now: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = max(1, capacity)
        self.now = now
    }

    public func get(_ key: AICacheKey) async -> CachedAIResult? {
        guard let entry = entries[key.digest] else { return nil }
        if let expires = entry.expires, expires <= now() {
            entries[key.digest] = nil
            return nil
        }
        return entry.value
    }

    public func put(_ key: AICacheKey, _ value: CachedAIResult, ttl: Duration?) async {
        sequence += 1
        let expires = ttl.map { now().addingTimeInterval(Self.seconds($0)) }
        entries[key.digest] = Entry(value: value, expires: expires, sequence: sequence)
        if let threadKey = key.threadKey { threadIndex[threadKey, default: []].insert(key.digest) }
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            entries[oldest] = nil
        }
    }

    public func invalidate(threadKey: String) async {
        for digest in threadIndex[threadKey] ?? [] { entries[digest] = nil }
        threadIndex[threadKey] = nil
    }

    public func removeAll() async {
        entries.removeAll()
        threadIndex.removeAll()
    }

    public var count: Int { entries.count }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
