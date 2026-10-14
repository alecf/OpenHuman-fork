import AppKit
import MailActions
import MailFeatures
import MailModel
import MailRender
import MailTheme
import MailUI
import OpenHumanCore

@MainActor
func readerText(_ text: String, _ style: TypeStyle, _ color: ThemeColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: style.font, .foregroundColor: color.nsColor, .paragraphStyle: style.paragraphStyle(lineBreak: .byTruncatingTail),
    ])
}

@MainActor
func readerLabel(_ text: String, _ style: TypeStyle, _ color: ThemeColor, lines: Int = 1) -> NSTextField {
    let field = NSTextField(labelWithAttributedString: readerText(text, style, color))
    field.maximumNumberOfLines = lines
    field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

@MainActor
final class ReaderButton: NSButton {
    var onPress: (() -> Void)?
    private var restTint: NSColor?
    private var activeTint: NSColor?
    private var hoverPlate: NSColor?
    private var pressPlate: NSColor?
    private var quietTint: NSColor?
    private var hoverTint: NSColor?
    private var isHovered = false { didSet { updatePlate(); updateTint() } }
    private var isPressed = false { didSet { updatePlate() } }
    var isActive = false { didSet { updateTint(); updateImage(); updateToggleValue() } }
    var isRaised = false { didSet { if isRaised != oldValue { updateTint() } } }
    private var restImage: NSImage?
    private var activeImage: NSImage?
    override var isEnabled: Bool { didSet { updateTint(); updatePlate() } }
    var tip: KeycapTooltipContent? {
        didSet {
            guard let tip else { return }
            toolTip = nil
            setAccessibilityHelp(tip.plainText)
        }
    }
    var onHoverChange: ((ReaderButton, Bool) -> Void)?
    var tipText: String? { tip?.plainText ?? toolTip }

    static func link(_ title: String, theme: ThemeTokens, style: TypeStyle? = nil, onPress: @escaping () -> Void) -> ReaderButton {
        let button = ReaderButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: (style ?? theme.typeLabel).font, .foregroundColor: theme.component.link.text.nsColor,
        ])
        button.finish(onPress)
        button.setAccessibilityLabel(title)
        return button
    }

    static func plain(_ title: String, theme: ThemeTokens) -> ReaderButton {
        let button = ReaderButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: theme.typeMeta.font, .foregroundColor: theme.textSecondary.nsColor,
        ])
        button.finish {}
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        button.setAccessibilityLabel(title)
        return button
    }

    static func icon(_ symbol: String, activeSymbol: String? = nil, help: String, theme: ThemeTokens, size: CGFloat = 28, pointSize: CGFloat = 13,
                     onPress: @escaping () -> Void) -> ReaderButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)) ?? NSImage()
        let button = ReaderButton(image: image, target: nil, action: nil)
        button.restImage = image
        button.activeImage = activeSymbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: help)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        }
        button.isBordered = false
        button.restTint = theme.textSecondary.nsColor
        button.activeTint = theme.accentText.nsColor
        button.hoverPlate = theme.bgRowHover.nsColor
        button.pressPlate = theme.bgRowSelected.nsColor
        button.wantsLayer = true
        button.layer?.cornerRadius = theme.radiusMD
        button.updateTint()
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.finish(onPress)
        button.updateToggleValue()
        button.widthAnchor.constraint(equalToConstant: size).isActive = true
        button.heightAnchor.constraint(equalToConstant: size).isActive = true
        return button
    }

    private func updateToggleValue() {
        guard activeImage != nil else { return }
        setAccessibilityValue(isActive ? "On" : "Off")
    }

    private func updateImage() {
        guard let activeImage else { return }
        image = isActive ? activeImage : restImage
    }

    func useQuietTints(_ theme: ThemeTokens) {
        quietTint = theme.textTertiary.nsColor
        hoverTint = theme.textPrimary.nsColor
        updateTint()
    }

    private func updateTint() {
        guard let restTint, let activeTint else { return }
        if !isEnabled {
            contentTintColor = restTint.withAlphaComponent(0.4)
        } else if isActive {
            contentTintColor = activeTint
        } else if isHovered, let hoverTint {
            contentTintColor = hoverTint
        } else {
            contentTintColor = isRaised ? restTint : (quietTint ?? restTint)
        }
    }

    private func updatePlate() {
        guard hoverPlate != nil else { return }
        let plate = !isEnabled ? nil : (isPressed ? pressPlate : (isHovered ? hoverPlate : nil))
        layer?.backgroundColor = plate?.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        guard hoverPlate != nil else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChange?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChange?(self, false)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    private func finish(_ onPress: @escaping () -> Void) {
        self.onPress = onPress
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @objc private func pressed() {
        onHoverChange?(self, false)
        onPress?()
    }
}

@MainActor
final class MessageCardView: NSView {
    enum Appearance: Equatable { case flat, raised }

    static func appearance(expanded: Bool, hovering: Bool, focused: Bool, hasComposer: Bool) -> Appearance {
        expanded || hasComposer || hovering || focused ? .raised : .flat
    }

    let fill: NSColor
    let border: NSColor
    let ring: NSColor?
    var showsFocusRing = false {
        didSet { if showsFocusRing != oldValue { needsDisplay = true } }
    }
    private let radius: CGFloat
    private let cardShadow: ThemeShadow
    private let hairline: CGFloat
    let margin: CGFloat
    var look: Appearance = .raised {
        didSet { if look != oldValue { needsDisplay = true } }
    }
    var segment: CardSegment = .single

    init(theme: ThemeTokens) {
        fill = theme.component.thread.cardBg.nsColor
        border = (theme.increaseContrast ? theme.borderControl : theme.borderElevated).nsColor
        ring = theme.increaseContrast ? theme.accentRing.nsColor : nil
        radius = theme.radiusLG
        cardShadow = theme.component.thread.cardShadow
        hairline = theme.borderWidthHairline
        margin = Self.margin(for: cardShadow)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func margin(for shadow: ThemeShadow) -> CGFloat {
        shadow.layers.map { $0.blur + max(abs($0.x), abs($0.y)) + max(0, $0.spread) }.max().map { $0.rounded(.up) } ?? 0
    }

    func pin(around view: NSView) {
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -margin),
            trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: margin),
            topAnchor.constraint(equalTo: view.topAnchor, constant: -margin),
            bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: margin),
        ])
    }

    var cardRect: NSRect { bounds.insetBy(dx: margin, dy: margin) }

    override func draw(_ dirtyRect: NSRect) {
        let card = cardRect
        guard look == .raised, card.width > 0, card.height > 0 else { return }
        let path = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
        let edge = NSBezierPath(roundedRect: card.insetBy(dx: hairline / 2, dy: hairline / 2), xRadius: radius, yRadius: radius)
        for layer in cardShadow.layers {
            NSGraphicsContext.saveGraphicsState()
            let cast = NSShadow()
            cast.shadowOffset = NSSize(width: layer.x, height: -layer.y)
            cast.shadowBlurRadius = layer.blur
            cast.shadowColor = layer.color.nsColor
            cast.set()
            fill.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        fill.setFill()
        path.fill()
        edge.lineWidth = hairline
        border.setStroke()
        edge.stroke()
        if showsFocusRing, let ring {
            let ringPath = edge.copy() as! NSBezierPath
            ringPath.lineWidth = Self.focusRingWidth
            ring.setStroke()
            ringPath.stroke()
        }
    }

    static let focusRingWidth: CGFloat = 1

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
func roundedPath(_ rect: NSRect, radius: CGFloat, top: Bool, bottom: Bool) -> NSBezierPath {
    let r = min(radius, rect.height / 2, rect.width / 2)
    let path = NSBezierPath()
    if bottom {
        path.move(to: NSPoint(x: rect.minX, y: rect.minY + r))
        path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 270, endAngle: 360)
    } else {
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    }
    if top {
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: rect.minX + r, y: rect.maxY))
        path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: 90, endAngle: 180)
    } else {
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
    }
    path.close()
    return path
}

@MainActor
final class FocusBarView: NSView {
    let color: NSColor
    private let radius: CGFloat

    init(theme: ThemeTokens) {
        color = theme.component.row.cursorBar.nsColor
        radius = theme.radiusLG
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: theme.component.thread.focusEdgeWidth).isActive = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        roundedPath(NSRect(x: 0, y: 0, width: bounds.width + radius * 2, height: bounds.height), radius: radius,
                    top: true, bottom: true).addClip()
        color.setFill()
        bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
final class FocusPlateView: NSView {
    let color: NSColor
    private let radius: CGFloat
    var roundsBottom = false { didSet { if roundsBottom != oldValue { needsDisplay = true } } }
    var roundsTop = true { didSet { if roundsTop != oldValue { needsDisplay = true } } }

    init(theme: ThemeTokens) {
        color = theme.component.row.bgCursor.nsColor
        radius = theme.radiusLG
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        roundedPath(bounds, radius: radius, top: roundsTop, bottom: roundsBottom).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class CollapsedMessageView: NSView {
    var onClick: (() -> Void)?
    let snippetLabel: NSTextField

    static func rowHeight(_ theme: ThemeTokens) -> CGFloat { theme.collapsedMessageRow + theme.space2 }

    static func senderColumn(_ theme: ThemeTokens) -> CGFloat { theme.component.row.senderMin }

    convenience init(_ message: ReaderModel.Message, theme: ThemeTokens, format: ThreadRowFormatting, now: Date) {
        self.init(summary: message.summary, theme: theme, format: format, now: now)
    }

    init(summary: MessageSummary, theme: ThemeTokens, format: ThreadRowFormatting, now: Date) {
        let sender = summary.from?.name ?? summary.from?.email ?? "Unknown sender"
        snippetLabel = readerLabel(summary.snippet, theme.typeBody, theme.textTertiary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let name = readerLabel(sender, theme.typeBodyStrong, summary.isUnread ? theme.textPrimary : theme.textSecondary)
        let snippet = snippetLabel
        let date = readerLabel(format.listDate(summary.date, now: now), theme.typeMeta, theme.textTertiary)
        date.setContentHuggingPriority(.required, for: .horizontal)
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [name, snippet, date] { addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight(theme)),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: Self.senderColumn(theme)),
            snippet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.senderColumn(theme) + theme.space5),
            snippet.centerYAnchor.constraint(equalTo: centerYAnchor),
            snippet.trailingAnchor.constraint(lessThanOrEqualTo: date.leadingAnchor, constant: -theme.space5),
            date.trailingAnchor.constraint(equalTo: trailingAnchor),
            date.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Collapsed message from \(sender), \(format.spokenListDate(summary.date, now: now)): \(summary.snippet)")
        setAccessibilityHelp("Expands the message")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

@MainActor
final class OlderMessagesPillView: NSView {
    var onClick: (() -> Void)?
    let count: Int
    private let card: MessageCardView
    var cardSegment: CardSegment {
        get { card.segment }
        set { card.segment = newValue }
    }
    var cardAppearance: MessageCardView.Appearance { card.look }

    init(count: Int, theme: ThemeTokens) {
        self.count = count
        card = MessageCardView(theme: theme)
        card.look = .flat
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let text = count == 1 ? "1 older message" : "\(count) older messages"
        let label = readerLabel(text, theme.typeLabel, theme.textSecondary)
        addSubview(card)
        addSubview(label)
        card.pin(around: self)
        let padding = MessageContainerView.horizontalPadding(theme)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CollapsedMessageView.rowHeight(theme)),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padding),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
        setAccessibilityHelp("Shows the older messages")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { card.look = .raised }
    override func mouseExited(with event: NSEvent) { card.look = .flat }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

@MainActor
struct MessageHeaderActions {
    var toggleDetails: () -> Void = {}
    var collapse: () -> Void = {}
    var perform: (ActionID) -> Void = { _ in }
    var availability: (ActionDescriptor) -> ReaderActions.Availability = { _ in .init(isEnabled: false, help: "") }
    var isOffered: (ActionDescriptor) -> Bool = { _ in true }
    var activateAccessory: () -> Void = {}
    var buildMenu: (NSMenu) -> Void = { _ in }
    var bindings: (ActionDescriptor) -> [KeyBinding] = { $0.defaultBindings }
    var tooltipHover: (ReaderButton, Bool) -> Void = { _, _ in }
}

@MainActor
final class MessageHeaderView: NSView {
    static let isOneLine = true
    private let theme: ThemeTokens
    private let summary: MessageSummary
    private let avatar: AvatarView
    private var nameAfterAvatar: NSLayoutConstraint!
    private var nameFlush: NSLayoutConstraint!
    private let recipients: ReaderButton
    private let detailsStack = NSStackView()
    private let actionsStack = NSStackView()
    private var moreButton: ReaderButton!
    private(set) var detailsButton: ReaderButton!
    private var accessoryButton: ReaderButton?
    private let lineTwo = NSStackView()
    var actions: MessageHeaderActions
    static let oneLineBand: CGFloat = 28
    let bodyGap: CGFloat
    var pasteboard: NSPasteboard = .general
    private(set) var detailsShown = false

    private(set) var vipBadge: NSTextField?

    init(_ summary: MessageSummary, me: Set<String>, theme: ThemeTokens, format: ThreadRowFormatting, reader: ReaderFormatting,
         now: Date, actions: MessageHeaderActions, isVIP: Bool = false) {
        self.theme = theme
        self.summary = summary
        self.actions = actions
        recipients = ReaderButton.plain(format.recipientsLine(summary, me: me), theme: theme)
        let email = summary.from?.email ?? ""
        avatar = AvatarView(initials: format.initials(name: summary.from?.name, email: email), email: email, theme: theme)
        let name = readerLabel(summary.from?.name ?? (email.isEmpty ? "Unknown sender" : email), theme.typeBodyStrong, theme.textPrimary)
        bodyGap = Self.isOneLine
            ? max(0, theme.space4 - max(0, Self.oneLineBand - name.intrinsicContentSize.height) / 2)
            : theme.space5
        super.init(frame: .zero)
        recipients.onPress = { [weak self] in self?.toggleDetails() }
        translatesAutoresizingMaskIntoConstraints = false
        if summary.from?.name != nil { name.toolTip = email }
        let date = readerLabel(format.headerDate(summary.date, now: now), theme.typeMeta, theme.textTertiary)
        name.setContentHuggingPriority(.required, for: .horizontal)
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)

        recipients.setAccessibilityHelp("Shows all recipients and the date")
        recipients.toolTip = "Show details"
        recipients.identifier = NSUserInterfaceItemIdentifier("reader.recipients")
        lineTwo.orientation = .horizontal
        lineTwo.spacing = theme.space2
        lineTwo.alignment = .firstBaseline
        lineTwo.translatesAutoresizingMaskIntoConstraints = false
        if isVIP {
            let badge = readerLabel("★ \(VIPCenter.chipTitle)", theme.typeMeta, theme.textWarning)
            badge.identifier = NSUserInterfaceItemIdentifier("reader.vip")
            badge.setAccessibilityLabel("VIP")
            badge.toolTip = "You marked this sender as a VIP: their mail is always important."
            lineTwo.addArrangedSubview(badge)
            vipBadge = badge
        }
        lineTwo.addArrangedSubview(recipients)

        actionsStack.orientation = .horizontal
        actionsStack.spacing = theme.space2
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        for descriptor in ReaderActions.messageActions where actions.isOffered(descriptor) {
            let availability = actions.availability(descriptor)
            let button = ReaderButton.icon(ReaderActions.symbol(for: descriptor.id) ?? "ellipsis", help: availability.help,
                                           theme: theme, pointSize: ShellMetrics.rowIconSize) { [weak self] in
                self?.actions.perform(descriptor.id)
            }
            button.isEnabled = availability.isEnabled
            button.useQuietTints(theme)
            button.identifier = NSUserInterfaceItemIdentifier(descriptor.id.rawValue)
            button.setAccessibilityLabel(descriptor.title)
            button.tip = KeycapTooltipContent.make(title: descriptor.title, bindings: actions.bindings(descriptor),
                                                   enabled: availability.isEnabled, reason: availability.help)
            actionsStack.addArrangedSubview(button)
        }
        let more = ReaderButton.icon("ellipsis", help: "More", theme: theme, pointSize: ShellMetrics.rowIconSize) { [weak self] in
            self?.showMenu()
        }
        more.identifier = NSUserInterfaceItemIdentifier("reader.more")
        more.setAccessibilityLabel("More actions for this message")
        more.setAccessibilityRole(.menuButton)
        more.tip = KeycapTooltipContent(title: "More")
        actionsStack.addArrangedSubview(more)
        moreButton = more
        let details = ReaderButton.icon("chevron.up.chevron.down", help: "Show details", theme: theme, size: 24,
                                        pointSize: 11) { [weak self] in
            self?.toggleDetails()
        }
        details.identifier = NSUserInterfaceItemIdentifier("reader.details")
        details.useQuietTints(theme)
        details.setAccessibilityLabel("Show details")
        details.tip = KeycapTooltipContent(title: "Show details")
        detailsButton = details
        for button in actionButtons + [details] {
            button.onHoverChange = { [weak self] button, inside in self?.actions.tooltipHover(button, inside) }
        }

        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = theme.space1
        detailsStack.translatesAutoresizingMaskIntoConstraints = false
        detailsStack.isHidden = true
        for line in reader.headerLines(summary) {
            detailsStack.addArrangedSubview(Self.detailRow(line, theme: theme, copy: { [weak self] text in self?.copy(text) }))
        }

        for v in [avatar, name, lineTwo, details, date, actionsStack, detailsStack] as [NSView] { addSubview(v) }
        let header = NSLayoutGuide()
        addLayoutGuide(header)
        nameAfterAvatar = name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: theme.space4)
        nameFlush = name.leadingAnchor.constraint(equalTo: leadingAnchor)
        let oneLine = Self.isOneLine
        avatar.isHidden = oneLine
        let recipientsPlacement = oneLine
            ? [lineTwo.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: theme.space2),
               lineTwo.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor)]
            : [lineTwo.leadingAnchor.constraint(equalTo: name.leadingAnchor),
               lineTwo.topAnchor.constraint(equalTo: name.bottomAnchor, constant: theme.space1)]
        let bandPlacement = oneLine
            ? [header.heightAnchor.constraint(equalToConstant: Self.oneLineBand),
               name.centerYAnchor.constraint(equalTo: header.centerYAnchor),
               actionsStack.centerYAnchor.constraint(equalTo: name.centerYAnchor)]
            : [header.heightAnchor.constraint(equalToConstant: theme.messageHeaderHeight),
               name.topAnchor.constraint(equalTo: topAnchor),
               actionsStack.topAnchor.constraint(equalTo: topAnchor)]
        NSLayoutConstraint.activate(recipientsPlacement + bandPlacement + [
            oneLine ? nameFlush : nameAfterAvatar,
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
            avatar.topAnchor.constraint(equalTo: topAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -theme.space4),
            details.leadingAnchor.constraint(equalTo: lineTwo.trailingAnchor, constant: theme.space1),
            details.centerYAnchor.constraint(equalTo: recipients.centerYAnchor),
            details.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -theme.space4),
            date.trailingAnchor.constraint(equalTo: trailingAnchor),
            date.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: date.leadingAnchor, constant: -theme.space3),
            detailsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: theme.space3),
            detailsStack.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detailsStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        bottomConstraintCollapsed = bottomAnchor.constraint(equalTo: header.bottomAnchor)
        bottomConstraintExpanded = bottomAnchor.constraint(equalTo: detailsStack.bottomAnchor)
        bottomConstraintCollapsed.isActive = true

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        self.menu = menu
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("From \(summary.from.map(ReaderFormatting.display) ?? "unknown sender"), \(format.headerDate(summary.date, now: now))")
    }

    private var bottomConstraintCollapsed: NSLayoutConstraint!
    private var bottomConstraintExpanded: NSLayoutConstraint!

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onBackgroundClick?() }

    func toggleDetails() {
        detailsShown.toggle()
        detailsStack.isHidden = !detailsShown
        if Self.isOneLine {
            avatar.isHidden = !detailsShown
            let (off, on) = detailsShown ? (nameFlush!, nameAfterAvatar!) : (nameAfterAvatar!, nameFlush!)
            off.isActive = false
            on.isActive = true
        }
        bottomConstraintCollapsed.isActive = !detailsShown
        bottomConstraintExpanded.isActive = detailsShown
        let label = detailsShown ? "Hide details" : "Show details"
        recipients.toolTip = label
        detailsButton.tip = KeycapTooltipContent(title: label)
        detailsButton.setAccessibilityLabel(label)
        actions.toggleDetails()
    }

    func setActionsVisible(_ visible: Bool) {
        for button in actionButtons where button !== moreButton { button.isRaised = visible }
        detailsButton.isRaised = visible
        moreButton.alphaValue = visible ? 1 : 0
    }

    var actionsVisible: Bool { moreButton.alphaValue > 0 }

    var actionButtons: [ReaderButton] { actionsStack.arrangedSubviews.compactMap { $0 as? ReaderButton } }

    func setAccessory(_ item: ReaderHeaderAccessoryItem?) {
        if let accessoryButton {
            lineTwo.removeArrangedSubview(accessoryButton)
            accessoryButton.removeFromSuperview()
            self.accessoryButton = nil
        }
        guard let item else { return }
        let button = ReaderButton.link("· " + item.title, theme: theme, style: theme.typeMeta) { [weak self] in
            self?.actions.activateAccessory()
        }
        button.setAccessibilityLabel(item.accessibilityLabel)
        lineTwo.addArrangedSubview(button)
        accessoryButton = button
    }

    var accessoryTitle: String? { accessoryButton?.attributedTitle.string }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func showMenu() {
        guard let menu else { return }
        let point = NSPoint(x: bounds.maxX - 28, y: isFlipped ? 36 : bounds.maxY - 36)
        menu.popUp(positioning: nil, at: point, in: self)
    }

    func fillMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let replies = ReaderActions.messageActions.filter { actions.isOffered($0) }
        for descriptor in replies {
            let availability = actions.availability(descriptor)
            let item = MenuAction(descriptor.title, enabled: availability.isEnabled) { [weak self] in
                self?.actions.perform(descriptor.id)
            }
            item.toolTip = availability.help
            menu.addItem(item)
        }
        if !replies.isEmpty { menu.addItem(.separator()) }
        if let from = summary.from {
            menu.addItem(MenuAction("Copy Address") { [weak self] in self?.copy(ReaderFormatting.copyText(from, includingName: false)) })
            menu.addItem(MenuAction("Copy Name and Address") { [weak self] in
                self?.copy(ReaderFormatting.copyText(from, includingName: true))
            })
        }
        menu.addItem(MenuAction(detailsShown ? "Hide Details" : "Show Details") { [weak self] in self?.toggleDetails() })
        actions.buildMenu(menu)
    }

    static func detailRow(_ line: ReaderFormatting.HeaderLine, theme: ThemeTokens, copy: @escaping (String) -> Void) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = theme.space3
        let label = readerLabel(line.label, theme.typeMeta, theme.textTertiary)
        label.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let value = NSTextField(wrappingLabelWithString: line.value)
        value.font = theme.typeMeta.font
        value.textColor = theme.textSecondary.nsColor
        value.isSelectable = true
        value.translatesAutoresizingMaskIntoConstraints = false
        value.setAccessibilityLabel("\(line.label): \(line.value)")
        row.addArrangedSubview(label)
        row.addArrangedSubview(value)
        if !line.addresses.isEmpty {
            let copyText = line.addresses.map { $0.email }.joined(separator: ", ")
            let button = ReaderButton.icon("doc.on.doc", help: "Copy \(line.label == "From" ? "address" : "addresses")",
                                           theme: theme, size: 16, pointSize: 10) { copy(copyText) }
            button.identifier = NSUserInterfaceItemIdentifier("reader.copy.\(line.label.lowercased())")
            row.addArrangedSubview(button)
        }
        return row
    }
}

extension MessageHeaderView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { fillMenu(menu) }
}

@MainActor
final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, state: NSControl.StateValue = .off, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.state = state
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }

    func perform() { handler() }
}

@MainActor
final class AvatarView: NSView {
    static let usesAccountColors = false
    private let fill: NSColor
    private let ring: NSColor?
    private let ringWidth: CGFloat

    init(initials: String, email: String, theme: ThemeTokens) {
        let avatar = theme.component.avatar
        let colored = Self.usesAccountColors
        fill = (colored ? theme.avatarFill(for: email) : avatar.bg).nsColor
        ring = colored ? nil : avatar.ring.nsColor
        ringWidth = theme.borderWidthHairline
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        var style = theme.typeCaption
        style.weight = 600
        let label = NSTextField(labelWithString: initials)
        label.font = style.font
        label.textColor = colored ? .white : avatar.text.nsColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: avatar.size), heightAnchor.constraint(equalToConstant: avatar.size),
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
        fill.setFill()
        circle.fill()
        guard let ring else { return }
        circle.lineWidth = ringWidth
        ring.setStroke()
        circle.stroke()
    }
}

@MainActor
final class RemoteImagesBannerView: NSView {
    let loadButton: ReaderButton
    let alwaysButton: ReaderButton?
    let text: String

    init(blockedCount: Int, alwaysEntry: String?, remembers: Bool, theme: ThemeTokens,
         load: @escaping () -> Void, always: @escaping () -> Void) {
        text = ReaderFormatting.imagesHiddenText(blockedCount: blockedCount)
        loadButton = ReaderButton.link("Load images", theme: theme, onPress: load)
        loadButton.toolTip = "Load this message's images once  ⇧I"
        if let alwaysEntry {
            let shown = RemoteContentPolicy.displayName(ofEntry: alwaysEntry)
            let title = alwaysEntry.hasPrefix("@") ? "Always for \(shown)" : "Always from \(shown)"
            let button = ReaderButton.link(title, theme: theme, onPress: always)
            let choice = remembers ? "Always load images from \(shown) (Settings › Privacy lists it)."
                : "Load images from \(shown) for the rest of this session (Mail can't remember this choice here)."
            button.toolTip = choice + " " + RemoteContentPolicy.unverifiedSenderNote
            alwaysButton = button
        } else {
            alwaysButton = nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = theme.bgSunken.nsColor.cgColor
        layer?.cornerRadius = theme.radiusMD
        let icon = NSImageView(image: NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))!)
        icon.contentTintColor = theme.textSecondary.nsColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = readerLabel(text, theme.typeBody, theme.textSecondary)
        let buttons = NSStackView(views: [loadButton] + (alwaysButton.map { [$0] } ?? []))
        buttons.spacing = theme.space5
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for v in [icon, label, buttons] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: theme.space4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: theme.space3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -theme.space4),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -theme.space4),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

@MainActor
final class ImagesShownView: NSView {
    let text: String
    let actionButton: ReaderButton?

    init(source: RemoteContentPolicy.Source, trackerCount: Int, theme: ThemeTokens, hide: @escaping () -> Void,
         stop: @escaping () -> Void) {
        text = ReaderFormatting.imagesShownText(source: source, trackerCount: trackerCount)
        switch source {
        case .once: actionButton = ReaderButton.link("Hide", theme: theme, style: theme.typeMeta, onPress: hide)
        case .allowlist: actionButton = ReaderButton.link("Stop", theme: theme, style: theme.typeMeta, onPress: stop)
        case .policy: actionButton = nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = readerLabel(text, theme.typeMeta, theme.textTertiary)
        let row = NSStackView(views: [label] + (actionButton.map { [$0] } ?? []))
        row.spacing = theme.space2
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

@MainActor
final class OutgoingMessageView: NSView {
    let id: UUID
    private let status: NSTextField
    private(set) var state: OutgoingMessage.State
    private let summary: String
    private let statusStyle: TypeStyle
    private let sendingColor: ThemeColor
    private let sentColor: ThemeColor

    init(_ message: OutgoingMessage, theme: ThemeTokens, format: ThreadRowFormatting) {
        id = message.id
        state = message.state
        let names = (message.to + message.cc).map(RecipientParser.displayName)
        summary = names.isEmpty ? "" : names.joined(separator: ", ")
        statusStyle = theme.typeMeta
        sendingColor = theme.textSecondary
        sentColor = theme.textSuccess
        status = readerLabel(Self.statusText(message.state), theme.typeMeta,
                             message.state == .sent ? theme.textSuccess : theme.textSecondary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let card = MessageCardView(theme: theme)
        addSubview(card)
        card.pin(around: self)
        let email = message.from.email
        let name = readerLabel(message.from.name ?? email, theme.typeBodyStrong, theme.textPrimary)
        let to = readerLabel(summary.isEmpty ? "" : "to \(summary)", theme.typeMeta, theme.textSecondary)
        let body = NSTextField(wrappingLabelWithString: message.text.trimmingCharacters(in: .whitespacesAndNewlines))
        body.font = theme.typeReader.font
        body.textColor = theme.textPrimary.nsColor
        body.maximumNumberOfLines = 0
        body.isSelectable = true
        body.translatesAutoresizingMaskIntoConstraints = false
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.setContentCompressionResistancePriority(.required, for: .vertical)
        name.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [name, to, status, body] as [NSView] { addSubview(v) }
        let padding = MessageContainerView.horizontalPadding(theme)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            name.topAnchor.constraint(equalTo: topAnchor, constant: theme.cardContentInsetY),
            name.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -theme.space5),
            to.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: theme.space2),
            to.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            to.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -theme.space5),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            status.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            body.topAnchor.constraint(equalTo: name.bottomAnchor, constant: theme.space4),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -theme.cardContentInsetY),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func statusText(_ state: OutgoingMessage.State) -> String {
        state == .sent ? "Sent" : "Sending…"
    }

    var statusText: String { status.stringValue }
    var statusColor: NSColor? { status.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor }
    var statusFont: NSFont? { status.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont }

    func update(_ message: OutgoingMessage) {
        guard message.state != state else { return }
        state = message.state
        status.attributedStringValue = readerText(Self.statusText(state), statusStyle, state == .sent ? sentColor : sendingColor)
        updateAccessibility()
    }

    private func updateAccessibility() {
        let what = summary.isEmpty ? "Your message" : "Your message to \(summary)"
        setAccessibilityLabel("\(what), \(Self.statusText(state).lowercased())")
    }
}
