import Foundation

public struct BoundedLRU<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var tick: UInt64
    }

    public let countLimit: Int
    public let costLimit: Int?
    private var entries: [Key: Entry] = [:]
    private var nextTick: UInt64 = 0
    public private(set) var totalCost = 0

    public init(countLimit: Int, costLimit: Int? = nil) {
        self.countLimit = max(countLimit, 1)
        self.costLimit = costLimit
    }

    public var count: Int { entries.count }

    public mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        nextTick += 1
        entry.tick = nextTick
        entries[key] = entry
        return entry.value
    }

    public func peek(_ key: Key) -> Value? { entries[key]?.value }

    public func contains(_ key: Key) -> Bool { entries[key] != nil }

    public mutating func insert(_ value: Value, for key: Key, cost: Int = 0) {
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
        if let costLimit, cost > costLimit { return }
        nextTick += 1
        entries[key] = Entry(value: value, cost: cost, tick: nextTick)
        totalCost += cost
        guard entries.count > countLimit || (costLimit.map { totalCost > $0 } ?? false) else { return }
        let countTarget = countLimit - countLimit / 10
        let costTarget = costLimit.map { $0 - $0 / 10 }
        let oldestFirst = entries.sorted { $0.value.tick < $1.value.tick }.map(\.key)
        for key in oldestFirst {
            let overCount = entries.count > countTarget
            let overCost = costTarget.map { totalCost > $0 } ?? false
            if !overCount && !overCost { break }
            totalCost -= entries.removeValue(forKey: key)?.cost ?? 0
        }
    }

    public mutating func removeAll() {
        entries = [:]
        totalCost = 0
    }
}

extension RenderedBody {
    public var approximateBytes: Int {
        switch self {
        case .html(let message): return message.html.utf8.count
        case .plain(let document): return document.blocks.reduce(0) { $0 + $1.text.utf8.count }
        case .empty: return 0
        }
    }
}
