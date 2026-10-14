import AppKit
import MailTheme

@MainActor
final class ThreadGroupHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ThreadGroupHeader")

    private let label = NSTextField(labelWithString: "")
    var style: ThreadRowStyle {
        didSet { if style !== oldValue { applyStyle() } }
    }

    init(style: ThreadRowStyle) {
        self.style = style
        super.init(frame: .zero)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityRoleDescription(String(localized: "heading"))
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var title: String { label.stringValue }

    var labelFrame: NSRect { label.frame }

    static let textInset: CGFloat = 2

    func configure(title: String) {
        guard title != label.stringValue else { return }
        label.stringValue = title
        setAccessibilityLabel(title)
        needsLayout = true
    }

    private func applyStyle() {
        label.font = style.theme.typeLabel.font
        label.textColor = style.tertiary
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        let x = style.metrics.leading, trailing = style.metrics.trailing
        let inset = Self.textInset
        let font = style.theme.typeLabel.font
        let baselineFromBottom: CGFloat = 9
        let y = (baselineFromBottom + font.descender).rounded()
        let width = max(0, bounds.width - x - trailing + 2 * inset)
        let rtl = userInterfaceLayoutDirection == .rightToLeft
        label.frame = NSRect(x: rtl ? bounds.width - x + inset - width : x - inset, y: y, width: width, height: height)
    }
}

@MainActor
final class ThreadGroupHeaderRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ThreadGroupHeaderRow")

    var background: NSColor {
        didSet { if background != oldValue { needsDisplay = true } }
    }

    init(background: NSColor) {
        self.background = background
        super.init(frame: .zero)
        identifier = Self.identifier
        selectionHighlightStyle = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func drawBackground(in dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}
