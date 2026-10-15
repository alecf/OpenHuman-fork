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
        checkBeforeHintDismissed = false
    }

    public var checkBeforeHintDismissed = false

    public func checkAll(in rows: [ThreadKey]) {
        guard let first = rows.first, let last = rows.last else { return }
        clearChecked()
        extend(to: last, from: first, in: rows)
    }

    public func checkFromHere(cursor: ThreadKey?, in rows: [ThreadKey]) {
        guard let cursor, rows.contains(cursor), !offersCheckBefore(in: rows) else { return checkAll(in: rows) }
        let dismissed = checkBeforeHintDismissed
        clearChecked()
        checkBeforeHintDismissed = dismissed
        if let last = rows.last { extend(to: last, from: cursor, in: rows) }
    }

    public func offersCheckBefore(in rows: [ThreadKey]) -> Bool {
        guard let start = rows.firstIndex(where: checked.contains), start > 0,
              checked.count == rows.count - start else { return false }
        return rows[start...].allSatisfy(checked.contains)
    }

    public func headerCheck(in rows: [ThreadKey]) -> SelectionHeaderCheck {
        guard !checked.isEmpty else { return .hidden }
        return !rows.isEmpty && rows.allSatisfy(checked.contains) ? .all : .some
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
