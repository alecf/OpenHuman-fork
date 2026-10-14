import AppKit
import MailTheme

@MainActor
public final class ThreadRowBackgroundView: NSTableRowView {
    public static let identifier = NSUserInterfaceItemIdentifier("ThreadRowBackground")

    var style: ThreadRowStyle {
        didSet { if style !== oldValue { needsDisplay = true } }
    }
    var isChecked = false {
        didSet { if isChecked != oldValue { needsDisplay = true } }
    }
    private(set) var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            needsDisplay = true
            (view(atColumn: 0) as? ThreadRowView)?.setHovering(isHovering)
        }
    }

    init(style: ThreadRowStyle) {
        self.style = style
        super.init(frame: .zero)
        identifier = Self.identifier
        selectionHighlightStyle = .regular
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isEmphasized: Bool {
        get { false }
        set {}
    }

    public override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            for case let cell as ThreadRowView in subviews { cell.setCursor(isSelected) }
        }
    }

    public override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? ThreadRowView)?.setCursor(isSelected)
    }

    public override func drawBackground(in dirtyRect: NSRect) {
        style.window.setFill()
        dirtyRect.fill()
        if isChecked {
            style.checked.setFill()
            plate.fill()
        } else if isHovering, !isSelected {
            style.hover.setFill()
            plate.fill()
        }
    }

    var drawsEdge: Bool { style.drawsPlateEdge }

    public override func drawSelection(in dirtyRect: NSRect) {
        let path = plate
        (isChecked ? style.checked : style.cursor).setFill()
        path.fill()
        if drawsEdge {
            let edge = style.plateRect(in: bounds).insetBy(dx: 0.5, dy: 0.5)
            let outline = NSBezierPath(roundedRect: edge, xRadius: max(0, style.plateRadius - 0.5),
                                       yRadius: max(0, style.plateRadius - 0.5))
            outline.lineWidth = 1
            style.plateEdge.setStroke()
            outline.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        style.cursorBar.setFill()
        let rect = style.plateRect(in: bounds), bar = style.cursorBarWidth
        let x = userInterfaceLayoutDirection == .rightToLeft ? rect.maxX - bar : rect.minX
        NSRect(x: x, y: rect.minY, width: bar, height: rect.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private var plate: NSBezierPath {
        NSBezierPath(roundedRect: style.plateRect(in: bounds), xRadius: style.plateRadius, yRadius: style.plateRadius)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { isHovering = true }
    public override func mouseExited(with event: NSEvent) { isHovering = false }

    public override func prepareForReuse() {
        super.prepareForReuse()
        isHovering = false
        isChecked = false
    }
}
