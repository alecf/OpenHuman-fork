import AppKit
import MailActions
import MailTheme

struct KeycapTooltipContent: Equatable {
    let title: String
    let keycaps: [String]
    var plainText: String

    init(title: String, keycaps: [String] = [], plainText: String? = nil) {
        self.title = title
        self.keycaps = keycaps
        self.plainText = plainText ?? title
    }

    static func make(title: String, bindings: [KeyBinding], enabled: Bool, reason: String?) -> KeycapTooltipContent {
        guard enabled else { return KeycapTooltipContent(title: reason ?? title) }
        guard let binding = bindings.first else { return KeycapTooltipContent(title: title) }
        return KeycapTooltipContent(title: title, keycaps: binding.keycaps, plainText: "\(title)  \(binding.description)")
    }
}

enum KeycapTooltipLayout {
    static func frame(anchor: NSRect, size: NSSize, bounds: NSRect, gap: CGFloat, margin: CGFloat, flipped: Bool) -> NSRect {
        let centred = anchor.midX - size.width / 2
        let x = max(bounds.minX + margin, min(centred, bounds.maxX - margin - size.width))
        let below: CGFloat, above: CGFloat, fitsBelow: Bool
        if flipped {
            below = anchor.maxY + gap
            above = anchor.minY - gap - size.height
            fitsBelow = below + size.height <= bounds.maxY - margin
        } else {
            below = anchor.minY - gap - size.height
            above = anchor.maxY + gap
            fitsBelow = below >= bounds.minY + margin
        }
        return NSRect(x: x, y: fitsBelow ? below : above, width: size.width, height: size.height)
    }
}

struct KeycapTooltipTiming: Equatable {
    let delay: Duration
    let warm: Duration

    init(delay: Duration, warm: Duration) {
        self.delay = delay
        self.warm = warm
    }

    init(theme: ThemeTokens) {
        self.init(delay: .milliseconds(Int(theme.motionTooltipDelay.rounded())),
                  warm: .milliseconds(Int(theme.motionTooltipWarm.rounded())))
    }

    func wait(sinceLastHidden: Duration?) -> Duration {
        guard let since = sinceLastHidden, since < warm else { return delay }
        return .zero
    }
}

@MainActor
final class KeycapTooltipView: NSView {
    private let theme: ThemeTokens
    private(set) var content: KeycapTooltipContent?
    private(set) var pillFrame: NSRect = .zero
    let shadowRoom: CGFloat

    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    init(theme: ThemeTokens) {
        self.theme = theme
        shadowRoom = MessageCardView.margin(for: theme.shadow2)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: theme.typeLabel.font, .foregroundColor: theme.component.toast.text.nsColor]
    }

    private var keycapAttributes: [NSAttributedString.Key: Any] {
        [.font: theme.typeKeycap.font, .foregroundColor: theme.component.toast.keycapText.nsColor]
    }

    private var paddingX: CGFloat { theme.space3 }
    private var paddingY: CGFloat { theme.space2 }
    private var keycapLead: CGFloat { theme.space4 }
    private static let sequenceGap: CGFloat = 6

    private func keycapWidth(_ text: String) -> CGFloat {
        let keycap = theme.component.keycap
        let width = ceil((text as NSString).size(withAttributes: keycapAttributes).width) + 2 * theme.space2
        return max(CGFloat(keycap.minWidth), width)
    }

    func pillSize(for content: KeycapTooltipContent) -> NSSize {
        let title = (content.title as NSString).size(withAttributes: titleAttributes)
        var width = ceil(title.width) + 2 * paddingX
        if !content.keycaps.isEmpty {
            width += keycapLead + content.keycaps.map(keycapWidth).reduce(0, +)
                + CGFloat(content.keycaps.count - 1) * Self.sequenceGap
        }
        let line = max(CGFloat(theme.typeLabel.lineHeight), content.keycaps.isEmpty ? 0 : CGFloat(theme.component.keycap.height))
        return NSSize(width: width, height: line + 2 * paddingY)
    }

    func show(_ content: KeycapTooltipContent, at pill: NSRect) {
        self.content = content
        pillFrame = pill
        frame = pill.insetBy(dx: -shadowRoom, dy: -shadowRoom)
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        isHidden = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        let pill = bounds.insetBy(dx: shadowRoom, dy: shadowRoom)
        let path = NSBezierPath(roundedRect: pill, xRadius: theme.radiusMD, yRadius: theme.radiusMD)
        let fill = theme.component.toast.bg.nsColor
        for layer in theme.shadow2.layers {
            NSGraphicsContext.saveGraphicsState()
            let cast = NSShadow()
            cast.shadowOffset = NSSize(width: layer.x, height: isFlipped ? layer.y : -layer.y)
            cast.shadowBlurRadius = layer.blur
            cast.shadowColor = layer.color.nsColor
            cast.set()
            fill.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        fill.setFill()
        path.fill()

        let title = NSAttributedString(string: content.title, attributes: titleAttributes)
        let titleSize = title.size()
        var x = pill.minX + paddingX
        title.draw(at: NSPoint(x: x, y: pill.midY - titleSize.height / 2))
        x += ceil(titleSize.width) + keycapLead
        let keycap = theme.component.keycap
        let capHeight = CGFloat(keycap.height)
        for (index, cap) in content.keycaps.enumerated() {
            if index > 0 { x += Self.sequenceGap }
            let width = keycapWidth(cap)
            let rect = NSRect(x: x, y: pill.midY - capHeight / 2, width: width, height: capHeight)
            theme.component.toast.keycapBg.nsColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: keycap.radius, yRadius: keycap.radius).fill()
            let text = NSAttributedString(string: cap, attributes: keycapAttributes)
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            x += width
        }
    }
}
