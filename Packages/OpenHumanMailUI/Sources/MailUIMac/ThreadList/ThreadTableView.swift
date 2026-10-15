import AppKit

@MainActor
public final class ThreadTableView: NSTableView {
    weak var listController: ThreadListViewController?

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if listController?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    public override func selectAll(_ sender: Any?) {
        listController?.checkAll()
    }

    public override func cancelOperation(_ sender: Any?) {
        if listController?.clearChecks() != true { super.cancelOperation(sender) }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return listController?.contextMenu(forRow: row)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if row >= 0, modifiers.isDisjoint(with: [.shift, .command, .control]),
           listController?.isCheckboxHit(row: row, at: point) == true {
            listController?.handleClick(row: row, extending: false, toggling: true)
            window?.makeFirstResponder(self)
            return
        }
        if row >= 0, modifiers.contains(.shift) || modifiers.contains(.command) {
            listController?.handleClick(row: row, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
            window?.makeFirstResponder(self)
            return
        }
        if row >= 0, event.clickCount == 1 { listController?.handleClick(row: row, extending: false, toggling: false) }
        super.mouseDown(with: event)
    }
}
