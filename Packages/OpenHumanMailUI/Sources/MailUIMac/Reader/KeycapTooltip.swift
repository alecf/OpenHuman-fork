import AppKit
import MailActions
import MailTheme
import MailUI

struct KeycapTooltipContent: Equatable {
    let title: String
    let keycaps: [String]
    let hint: String?
    var plainText: String

    init(title: String, keycaps: [String] = [], hint: String? = nil, plainText: String? = nil) {
        self.title = title
        self.keycaps = keycaps
        self.hint = hint
        self.plainText = plainText ?? title
    }

    init(_ tip: ShortcutTip) {
        self.init(title: tip.title, keycaps: tip.keycaps, hint: tip.hint)
    }

    static func make(title: String, bindings: [KeyBinding], enabled: Bool, reason: String?) -> KeycapTooltipContent {
        guard enabled else { return KeycapTooltipContent(title: reason ?? title) }
        guard let binding = bindings.first else {
            return KeycapTooltipContent(title: ShortcutTip.displayTitle(title), plainText: title)
        }
        return KeycapTooltipContent(title: ShortcutTip.displayTitle(title), keycaps: binding.separatedKeycaps,
                                    plainText: "\(title)  \(binding.description)")
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

typealias KeycapTooltipTiming = ShortcutTipTiming

@MainActor
final class KeycapTooltipView: NSView {
    var theme: ThemeTokens {
        didSet { needsDisplay = true }
    }
    private(set) var content: KeycapTooltipContent?
    private(set) var pillFrame: NSRect = .zero
    var shadowRoom: CGFloat { MessageCardView.margin(for: theme.shadow2) }

    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    init(theme: ThemeTokens) {
        self.theme = theme
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

    private var hintAttributes: [NSAttributedString.Key: Any] {
        [.font: theme.typeLabel.font, .foregroundColor: theme.component.toast.textSecondary.nsColor]
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
        var height = rowHeight(content) + 2 * paddingY
        if let hint = content.hint {
            let size = (hint as NSString).size(withAttributes: hintAttributes)
            width = max(width, ceil(size.width) + 2 * paddingX)
            height += theme.space1 + CGFloat(theme.typeLabel.lineHeight)
        }
        return NSSize(width: width, height: height)
    }

    private func rowHeight(_ content: KeycapTooltipContent) -> CGFloat {
        max(CGFloat(theme.typeLabel.lineHeight), content.keycaps.isEmpty ? 0 : CGFloat(theme.component.keycap.height))
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

        let row = rowHeight(content)
        let rowMidY = isFlipped ? pill.minY + paddingY + row / 2 : pill.maxY - paddingY - row / 2
        if let hint = content.hint {
            let line = CGFloat(theme.typeLabel.lineHeight)
            let y = isFlipped ? pill.maxY - paddingY - line : pill.minY + paddingY
            NSAttributedString(string: hint, attributes: hintAttributes)
                .draw(in: NSRect(x: pill.minX + paddingX, y: y, width: pill.width - 2 * paddingX, height: line))
        }
        let title = NSAttributedString(string: content.title, attributes: titleAttributes)
        let titleSize = title.size()
        var x = pill.minX + paddingX
        title.draw(at: NSPoint(x: x, y: rowMidY - titleSize.height / 2))
        x += ceil(titleSize.width) + keycapLead
        let keycap = theme.component.keycap
        let capHeight = CGFloat(keycap.height)
        for (index, cap) in content.keycaps.enumerated() {
            if index > 0 { x += Self.sequenceGap }
            let width = keycapWidth(cap)
            let rect = NSRect(x: x, y: rowMidY - capHeight / 2, width: width, height: capHeight)
            theme.component.toast.keycapBg.nsColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: keycap.radius, yRadius: keycap.radius).fill()
            let text = NSAttributedString(string: cap, attributes: keycapAttributes)
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            x += width
        }
    }
}

@MainActor
final class KeycapTooltipPresenter {
    let view: KeycapTooltipView
    private var timing: KeycapTooltipTiming
    private var task: Task<Void, Never>?
    private(set) weak var anchor: NSView?
    private var hiddenAt: ContinuousClock.Instant?
    private var resignObserver: NSObjectProtocol?

    init(theme: ThemeTokens) {
        view = KeycapTooltipView(theme: theme)
        timing = KeycapTooltipTiming(theme: theme)
    }

    isolated deinit {
        task?.cancel()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func apply(theme: ThemeTokens) {
        guard theme != view.theme else { return }
        hide()
        view.theme = theme
        timing = KeycapTooltipTiming(theme: theme)
    }

    func hover(_ button: NSView, content: KeycapTooltipContent?, inside: Bool) {
        guard inside, let content else {
            if button === anchor { hide() }
            return
        }
        task?.cancel()
        task = nil
        let since: Duration? = view.isHidden ? hiddenAt.map { ContinuousClock.now - $0 } : .zero
        let wait = timing.wait(sinceLastHidden: since)
        anchor = button
        guard wait > .zero else { return show(content, for: button) }
        task = Task { @MainActor [weak self, weak button] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, let button, self.anchor === button else { return }
            self.task = nil
            self.show(content, for: button)
        }
    }

    func show(_ content: KeycapTooltipContent, for button: NSView) {
        guard let root = view.superview, button.isDescendant(of: root), !button.isHiddenOrHasHiddenAncestor else { return }
        task?.cancel()
        task = nil
        anchor = button
        let pill = KeycapTooltipLayout.frame(anchor: button.convert(button.bounds, to: root), size: view.pillSize(for: content),
                                             bounds: root.bounds, gap: KeycapTooltipView.gap, margin: KeycapTooltipView.margin,
                                             flipped: root.isFlipped)
        view.show(content, at: pill)
        observeResignKey(of: root.window)
    }

    func hide() {
        task?.cancel()
        task = nil
        anchor = nil
        guard !view.isHidden else { return }
        view.hide()
        hiddenAt = .now
    }

    private func observeResignKey(of window: NSWindow?) {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let window else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }
}
