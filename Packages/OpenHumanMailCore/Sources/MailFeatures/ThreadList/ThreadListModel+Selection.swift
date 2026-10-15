import Foundation
import MailModel

extension ThreadListModel {
    public var checkedCount: Int { selection.checked.count }

    public func isChecked(_ key: ThreadKey) -> Bool { selection.checked.contains(key) }

    public var actionTargets: [ThreadKey] {
        guard !selection.checked.isEmpty else { return cursor.map { [$0] } ?? [] }
        return selection.targets(cursor: cursor, order: rows.map(\.id))
    }

    @discardableResult
    public func toggleCheck(_ key: ThreadKey? = nil) -> Bool {
        guard let key = key ?? cursor, index(of: key) != nil else { return false }
        selection.toggle(key)
        return true
    }

    @discardableResult
    public func extendCheck(by delta: Int) -> Bool {
        guard let start = cursor else { return false }
        if selection.anchor == nil { selection.extend(to: start, from: start, in: [start]) }
        guard moveCursor(by: delta), let end = cursor else { return false }
        selection.extend(to: end, from: start, in: rows.map(\.id))
        return true
    }

    public func checkAll() {
        selection.checkAll(in: rows.map(\.id))
    }

    public func checkFromHere() {
        selection.checkFromHere(cursor: cursor, in: rows.map(\.id))
    }

    public var headerCheck: SelectionHeaderCheck { selection.headerCheck(in: rows.map(\.id)) }

    public var offersCheckBefore: Bool {
        !selection.checkBeforeHintDismissed && selection.offersCheckBefore(in: rows.map(\.id))
    }

    public func headerCheckClicked() {
        if headerCheck == .all { clearChecks() } else { checkAll() }
    }

    @discardableResult
    public func clearChecks() -> Bool {
        guard !selection.checked.isEmpty || selection.anchor != nil else { return false }
        selection.clearChecked()
        return true
    }

    public func click(_ key: ThreadKey, extending: Bool = false, toggling: Bool = false) {
        guard index(of: key) != nil else { return }
        if toggling {
            selection.toggle(key)
        } else if extending {
            selection.extend(to: key, from: cursor ?? key, in: rows.map(\.id))
        } else if !selection.checked.isEmpty || selection.anchor != nil {
            selection.clearChecked()
        }
        setCursor(key)
    }
}
