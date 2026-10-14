import Foundation
import MailModel
import Observation

@MainActor
@Observable
public final class SelectionModel {
    public private(set) var checked: Set<ThreadKey> = []
    public private(set) var anchor: ThreadKey?
    public internal(set) var pendingCursor: ThreadKey?
    public var scrollTop: ThreadKey?
    public var scrollOffset: Double = 0

    public init() {}

    public func toggle(_ key: ThreadKey) {
        if checked.remove(key) == nil { checked.insert(key) }
        anchor = key
    }

    public func extend(to key: ThreadKey, from start: ThreadKey?, in rows: [ThreadKey]) {
        let origin = anchor ?? start ?? key
        guard let a = rows.firstIndex(of: origin), let b = rows.firstIndex(of: key) else {
            checked.insert(key)
            return
        }
        checked.formUnion(rows[min(a, b)...max(a, b)])
        anchor = origin
    }

    func restoreChecked(_ keys: [ThreadKey]) {
        checked = Set(keys)
        anchor = keys.last
    }

    public func clearChecked() {
        checked.removeAll()
        anchor = nil
    }

    public func prune(keeping present: Set<ThreadKey>) {
        checked.formIntersection(present)
        if let anchor, !present.contains(anchor) { self.anchor = nil }
    }

    public func targets(cursor: ThreadKey?, order rows: [ThreadKey]) -> [ThreadKey] {
        guard !checked.isEmpty else { return cursor.map { [$0] } ?? [] }
        let ordered = rows.filter(checked.contains)
        let missing = checked.subtracting(ordered).sorted { $0.rowID < $1.rowID }
        return ordered + missing
    }
}
