import Foundation
import MailModel

public struct ThreadListSnapshot: Sendable {
    public internal(set) var rows: [ThreadRow]
    private var baseIndex: [ThreadKey: Int]
    private var removedBase: [Int] = []
    public internal(set) var placeholderCount: Int
    public internal(set) var totalCount: Int
    public internal(set) var hasMore: Bool

    public init(rows: [ThreadRow], placeholderCount: Int = 0, totalCount: Int? = nil, hasMore: Bool = false) {
        self.rows = rows
        var index: [ThreadKey: Int] = [:]
        index.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() { index[row.id] = i }
        self.baseIndex = index
        self.placeholderCount = placeholderCount
        self.totalCount = totalCount ?? rows.count
        self.hasMore = hasMore
    }

    public static let empty = ThreadListSnapshot(rows: [])

    public var displayCount: Int { rows.count + placeholderCount }

    public func index(of key: ThreadKey) -> Int? {
        guard let base = baseIndex[key] else { return nil }
        guard !removedBase.isEmpty else { return base }
        var low = 0, high = removedBase.count
        while low < high {
            let mid = (low + high) / 2
            if removedBase[mid] < base { low = mid + 1 } else { high = mid }
        }
        if low < removedBase.count, removedBase[low] == base { return nil }
        return base - low
    }

    mutating func remove(_ keys: Set<ThreadKey>) -> IndexSet {
        var removed = IndexSet()
        var bases: [Int] = []
        for key in keys {
            guard let i = index(of: key), let base = baseIndex[key] else { continue }
            removed.insert(i)
            bases.append(base)
        }
        guard !removed.isEmpty else { return removed }
        var kept: [ThreadRow] = []
        kept.reserveCapacity(rows.count - removed.count)
        var start = 0
        for range in removed.rangeView {
            kept.append(contentsOf: rows[start..<range.lowerBound])
            start = range.upperBound
        }
        kept.append(contentsOf: rows[start...])
        rows = kept
        removedBase = (removedBase + bases).sorted()
        return removed
    }
}

public func releaseOffMain<T: Sendable>(_ value: T) {
    Task.detached(priority: .utility) { withExtendedLifetime(value) {} }
}

public enum ThreadListChange: Sendable, Equatable {
    case reload
    case update(ThreadListEdit)

    public static let none = ThreadListChange.update(ThreadListEdit())
}

public struct ThreadListEdit: Sendable, Equatable {
    public var removed = IndexSet()
    public var inserted = IndexSet()
    public var reconfigured = IndexSet()

    public init(removed: IndexSet = IndexSet(), inserted: IndexSet = IndexSet(), reconfigured: IndexSet = IndexSet()) {
        self.removed = removed
        self.inserted = inserted
        self.reconfigured = reconfigured
    }

    public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && reconfigured.isEmpty }

    public static let maximumIncremental = 300

    public static func between(_ old: ThreadListSnapshot, _ new: ThreadListSnapshot,
                               candidates: Set<ThreadKey>? = nil) -> ThreadListChange {
        let oldR = old.rows.count, newR = new.rows.count
        var removed = IndexSet(), inserted = IndexSet(), reconfigured = IndexSet()

        let appendOnly = newR > oldR && old.rows.indices.allSatisfy { i in new.rows[i].id == old.rows[i].id }
        if appendOnly, old.placeholderCount - new.placeholderCount == newR - oldR {
            reconfigured.insert(integersIn: oldR..<newR)
            addContentChanges(old, new, candidates: candidates, prefix: oldR, into: &reconfigured)
            return .update(ThreadListEdit(reconfigured: reconfigured))
        }

        var moved = Set<ThreadKey>()
        var i = 0, j = 0
        while i < oldR, j < newR {
            let ok = old.rows[i].id, nk = new.rows[j].id
            if new.index(of: ok) == nil || moved.contains(ok) { i += 1; continue }
            if old.index(of: nk) == nil { j += 1; continue }
            if ok == nk { i += 1; j += 1; continue }
            moved.insert(nk)
            j += 1
            if moved.count > maximumIncremental { return .reload }
        }
        for (index, row) in old.rows.enumerated() where new.index(of: row.id) == nil || moved.contains(row.id) {
            removed.insert(index)
        }
        for (index, row) in new.rows.enumerated() where old.index(of: row.id) == nil || moved.contains(row.id) {
            inserted.insert(index)
        }
        if new.placeholderCount > old.placeholderCount {
            inserted.insert(integersIn: (newR + old.placeholderCount)..<(newR + new.placeholderCount))
        } else if new.placeholderCount < old.placeholderCount {
            removed.insert(integersIn: (oldR + new.placeholderCount)..<(oldR + old.placeholderCount))
        }
        guard removed.count + inserted.count <= maximumIncremental else { return .reload }

        for key in candidates ?? Set(new.rows.map(\.id)) where !moved.contains(key) {
            guard let n = new.index(of: key), let o = old.index(of: key), old.rows[o] != new.rows[n] else { continue }
            reconfigured.insert(n)
        }
        return .update(ThreadListEdit(removed: removed, inserted: inserted, reconfigured: reconfigured))
    }

    private static func addContentChanges(_ old: ThreadListSnapshot, _ new: ThreadListSnapshot,
                                          candidates: Set<ThreadKey>?, prefix: Int, into set: inout IndexSet) {
        if let candidates {
            for key in candidates {
                guard let o = old.index(of: key), o < prefix, old.rows[o] != new.rows[o] else { continue }
                set.insert(o)
            }
        } else {
            for o in 0..<prefix where old.rows[o] != new.rows[o] { set.insert(o) }
        }
    }
}

struct ThreadListPage: Sendable {
    var after: PageCursor?
    var rows: [ThreadRow]
    var next: PageCursor?
    var generation: Int
    var fetchedAt: Date
}

struct ThreadListAssembler: Sendable {
    let sortsAscending: Bool
    var live: [ThreadRow] = []
    var liveTotal = 0
    var liveHasMore = false
    var pages: [ThreadListPage] = []
    var pagingFinished = false
    var pagingUnavailable = false
    var overlay = ThreadListOverlay()
    var previous = ThreadListSnapshot.empty
    var dirtyKeys = Set<ThreadKey>()
    var ordersByRelevance = false

    init(sortsAscending: Bool) {
        self.sortsAscending = sortsAscending
    }

    func baseRows() -> [ThreadRow] {
        guard liveHasMore, !pages.isEmpty, let boundary = live.last else { return live }
        var rows = live
        var seen = Set<ThreadKey>(minimumCapacity: live.count + pages.count * ThreadListModel.pageSize)
        for row in live { seen.insert(row.id) }
        for page in pages {
            for row in page.rows where !seen.contains(row.id) {
                guard ordersByRelevance || sorts(row, after: boundary) else { continue }
                seen.insert(row.id)
                rows.append(row)
            }
        }
        return rows
    }

    func sorts(_ row: ThreadRow, after boundary: ThreadRow) -> Bool {
        let lhs = (row.sortAt, row.id.rowID), rhs = (boundary.sortAt, boundary.id.rowID)
        return sortsAscending ? lhs > rhs : lhs < rhs
    }

    mutating func assemble() -> (snapshot: ThreadListSnapshot, change: ThreadListChange, settled: [Int]) {
        let base = baseRows()
        var settled: [Int] = []
        if !overlay.isEmpty {
            var baseIndex: [ThreadKey: Int] = [:]
            let touched = overlay.touchedKeys
            for (i, row) in base.enumerated() where touched.contains(row.id) { baseIndex[row.id] = i }
            settled = overlay.confirm { key in baseIndex[key].map { base[$0] } }
        }
        let (rows, hiddenCount) = overlay.apply(to: base)
        let estimatedTotal = max(liveTotal - hiddenCount, rows.count)
        let hasMore = liveHasMore && !pagingFinished
        let placeholders = hasMore && !pagingUnavailable ? max(0, estimatedTotal - rows.count) : 0
        let snapshot = ThreadListSnapshot(rows: rows, placeholderCount: placeholders, totalCount: estimatedTotal,
                                          hasMore: hasMore)
        var candidates = dirtyKeys.union(overlay.touchedKeys)
        for row in live { candidates.insert(row.id) }
        let change = ThreadListEdit.between(previous, snapshot, candidates: candidates)
        previous = snapshot
        dirtyKeys = []
        return (snapshot, change, settled)
    }
}
