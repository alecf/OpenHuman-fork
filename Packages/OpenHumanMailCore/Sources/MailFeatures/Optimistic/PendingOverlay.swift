import Foundation

public struct PendingOverlay<Key: Hashable & Sendable, Patch: Sendable>: Sendable {
    public struct Entry: Sendable {
        public var hidden: Bool
        public var patch: Patch?
        public var operations: [UUID]
        public var expiresAt: Date
    }

    public static var lifetime: TimeInterval { 10 }

    public private(set) var entries: [Key: Entry] = [:]
    private var undoLog: [UUID: [(Key, Entry?)]] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func hide(_ keys: [Key], operation: UUID, now: Date) {
        for key in keys {
            record(key, operation)
            var entry = entries[key] ?? Entry(hidden: false, patch: nil, operations: [], expiresAt: now)
            entry.hidden = true
            entry.operations.append(operation)
            entry.expiresAt = now.addingTimeInterval(Self.lifetime)
            entries[key] = entry
        }
    }

    public mutating func patch(_ key: Key, _ patch: Patch, operation: UUID, now: Date,
                               merge: (Patch, Patch) -> Patch = { _, newer in newer }) {
        record(key, operation)
        var entry = entries[key] ?? Entry(hidden: false, patch: nil, operations: [], expiresAt: now)
        entry.patch = entry.patch.map { merge($0, patch) } ?? patch
        entry.operations.append(operation)
        entry.expiresAt = now.addingTimeInterval(Self.lifetime)
        entries[key] = entry
    }

    public mutating func revert(_ operation: UUID) {
        guard let log = undoLog.removeValue(forKey: operation) else { return }
        for (key, previous) in log.reversed() {
            guard let current = entries[key], current.operations.last == operation else { continue }
            entries[key] = previous
        }
    }

    public mutating func settle(where isReflected: (Key, Entry) -> Bool) {
        for (key, entry) in entries where isReflected(key, entry) { drop(key) }
    }

    public mutating func expire(asOf date: Date) {
        for (key, entry) in entries where entry.expiresAt <= date { drop(key) }
    }

    public func isHidden(_ key: Key) -> Bool { entries[key]?.hidden ?? false }

    public func patch(for key: Key) -> Patch? { entries[key]?.patch }

    public func apply<Row>(to rows: [Row], key: (Row) -> Key, patching: (Row, Patch) -> Row) -> [Row] {
        guard !entries.isEmpty else { return rows }
        return rows.compactMap { row in
            guard let entry = entries[key(row)] else { return row }
            if entry.hidden { return nil }
            return entry.patch.map { patching(row, $0) } ?? row
        }
    }

    private mutating func record(_ key: Key, _ operation: UUID) {
        undoLog[operation, default: []].append((key, entries[key]))
    }

    private mutating func drop(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        for operation in entry.operations {
            undoLog[operation]?.removeAll { $0.0 == key }
            if undoLog[operation]?.isEmpty == true { undoLog[operation] = nil }
        }
    }
}
