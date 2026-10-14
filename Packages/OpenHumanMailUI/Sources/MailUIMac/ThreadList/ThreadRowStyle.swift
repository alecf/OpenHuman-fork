import AppKit
import MailFeatures
import MailModel
import MailTheme

@MainActor
final class ThreadRowStyle {
    let theme: ThemeTokens
    let row: ThemeTokens.Components.Row
    let rowHeight: CGFloat
    let lineHeight: CGFloat
    let bodyFont: NSFont
    let strongFont: NSFont
    let unreadFont: NSFont
    let metaFont: NSFont
    let chipDotFont: NSFont
    let chips: LabelChipRenderer
    var chipFont: NSFont { chips.chipFont }
    var chipType: TypeStyle { chips.chipType }
    static var minimumChipTextSize: Double { LabelChipRenderer.minimumTextSize }
    let window: NSColor
    let primary: NSColor
    let secondary: NSColor
    let snippet: NSColor
    let tertiary: NSColor
    let success: NSColor
    let warning: NSColor
    let danger: NSColor
    let accentRing: NSColor
    let accentFill: NSColor
    let accentOnFill: NSColor
    let hover: NSColor
    let cursor: NSColor
    let checked: NSColor
    let cursorBar: NSColor
    let plateEdge: NSColor
    let drawsPlateEdge: Bool
    let actionTint: NSColor
    let actionTintUnderPointer: NSColor
    let actionPointerFill: NSColor
    let actionPressedFill: NSColor
    let unreadDot: NSColor
    let senderColor: NSColor
    let ai: NSColor
    let plateInsetX: CGFloat
    let plateInsetY: CGFloat
    let plateRadius: CGFloat
    let cursorBarWidth: CGFloat
    let hoverTarget: CGFloat
    static let senderIsAlwaysStrong = true
    static let chipsAreFilled = true
    static let maximumFilledChips = 2
    static let dimRun = NSAttributedString.Key("oh.row.dim")
    private var cursorVariants: [(source: NSAttributedString, variant: NSAttributedString)] = []
    private let spaceWidth: CGFloat
    private let metaSpaceWidth: CGFloat
    private let truncating: NSParagraphStyle
    private let rightAligned: NSParagraphStyle
    private let baseline: CGFloat
    private var symbols: [String: NSImage] = [:]

    private struct Entry {
        let row: ThreadRow
        let chips: [ThreadRowChip]
        let draftPrefix: Bool
        let muted: Bool
        let followUpReason: String?
        let sender: NSAttributedString
        let line: NSAttributedString
    }

    private var texts: [ThreadKey: Entry] = [:]
    private var dates: [String: NSAttributedString] = [:]
    static let cacheLimit = 4_000

    let metrics: Metrics

    init(theme base: ThemeTokens) {
        let theme = Self.densityTyped(base)
        self.theme = theme
        metrics = Self.metrics(base)
        row = theme.component.row
        rowHeight = theme.rowHeight
        lineHeight = theme.typeBody.lineHeight
        bodyFont = theme.typeBody.font
        strongFont = theme.typeBodyStrong.font
        var unread = theme.typeBody
        unread.weight = Int(theme.component.row.unreadWeight)
        if Self.openness(theme) > 0 { unread.weight = max(unread.weight, theme.typeLabel.weight) }
        unreadFont = unread.font
        metaFont = theme.typeMeta.font
        chipDotFont = NSFont.systemFont(ofSize: max(6, theme.typeMeta.size * 0.6))
        chips = LabelChipRenderer(theme: theme)
        window = theme.bgWindow.nsColor
        primary = theme.component.row.subject.nsColor
        secondary = theme.textSecondary.nsColor
        snippet = theme.component.row.snippet.nsColor
        tertiary = theme.textTertiary.nsColor
        success = theme.component.row.draft.nsColor
        warning = theme.component.row.snoozed.nsColor
        danger = theme.textDanger.nsColor
        accentRing = theme.accentRing.nsColor
        accentFill = theme.accentFill.nsColor
        accentOnFill = theme.accentOnFill.nsColor
        hover = theme.component.row.bgHover.nsColor
        cursor = Self.cursorFill(theme).nsColor
        checked = theme.component.row.bgChecked.nsColor
        cursorBar = theme.component.row.cursorBar.nsColor
        plateEdge = theme.borderControl.nsColor
        drawsPlateEdge = theme.increaseContrast
        actionTint = Self.glyphTint(theme).nsColor
        actionTintUnderPointer = theme.listActionTintUnderPointer.nsColor
        actionPointerFill = theme.listActionPointerFill.nsColor
        actionPressedFill = theme.listActionPressedFill.nsColor
        unreadDot = theme.component.row.unreadDot.nsColor
        senderColor = theme.component.row.sender.nsColor
        ai = theme.textAI.nsColor
        plateInsetX = CGFloat(theme.listPlateInsetX)
        plateInsetY = CGFloat(theme.listPlateInsetY)
        hoverTarget = CGFloat(theme.listHoverTarget)
        plateRadius = CGFloat(theme.component.row.cursorRadius) * (1 + Self.openness(theme) * 2 / 3)
        cursorBarWidth = CGFloat(theme.component.row.cursorBarWidth)
        spaceWidth = (" " as NSString).size(withAttributes: [.font: bodyFont]).width
        metaSpaceWidth = (" " as NSString).size(withAttributes: [.font: metaFont]).width
        truncating = theme.typeBody.paragraphStyle(lineBreak: .byTruncatingTail)
        let right = theme.typeBody.paragraphStyle(lineBreak: .byClipping).mutableCopy() as! NSMutableParagraphStyle
        right.alignment = .right
        rightAligned = right
        baseline = theme.typeBody.baselineOffset
    }

    private func attributes(_ font: NSFont, _ color: NSColor, extra: [NSAttributedString.Key: Any] = [:])
        -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .baselineOffset: baseline,
                                                     .paragraphStyle: truncating]
        for (key, value) in extra { result[key] = value }
        return result
    }

    func plateRect(in bounds: NSRect) -> NSRect { bounds.insetBy(dx: plateInsetX, dy: plateInsetY) }

    static func cursorFill(_ theme: ThemeTokens) -> ThemeColor { theme.listCursorFill }

    static func glyphTint(_ theme: ThemeTokens) -> ThemeColor { theme.listActionTint }

    func symbol(_ name: String, color: NSColor) -> NSImage? {
        let key = name + "|" + color.description
        if let image = symbols[key] { return image }
        let config = NSImage.SymbolConfiguration(pointSize: metrics.indicatorSize, weight: .light)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        symbols[key] = image
        return image
    }

    private func retire<K, V>(_ cache: inout [K: V]) {
        let old = Retired(cache)
        cache = [:]
        releaseOffMain(old)
    }

    func forget() {
        texts.removeAll(keepingCapacity: true)
        dates.removeAll(keepingCapacity: true)
        formattedDates.removeAll(keepingCapacity: true)
        cursorVariants.removeAll()
    }

    func onCursor(_ text: NSAttributedString) -> NSAttributedString {
        if let hit = cursorVariants.first(where: { $0.source === text }) { return hit.variant }
        let copy = NSMutableAttributedString(attributedString: text)
        copy.enumerateAttribute(Self.dimRun, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            if value != nil { copy.addAttribute(.foregroundColor, value: secondary, range: range) }
        }
        cursorVariants.insert((text, copy), at: 0)
        if cursorVariants.count > 4 { cursorVariants.removeLast() }
        return copy
    }

    private static let draftWord = String(localized: "Draft")
    private static let noSubject = String(localized: "(no subject)")

    func texts(for row: ThreadRow, chips: [ThreadRowChip], format: ThreadRowFormatting,
               location: MailLocation, muted: Bool = false,
               followUpReason: String? = nil) -> (sender: NSAttributedString, line: NSAttributedString) {
        let draftPrefix = format.showsDraftPrefix(row, location: location)
        if let entry = texts[row.id], entry.row == row, entry.chips == chips, entry.draftPrefix == draftPrefix,
           entry.muted == muted, entry.followUpReason == followUpReason {
            return (entry.sender, entry.line)
        }
        if texts.count >= Self.cacheLimit { retire(&texts) }
        let sender = makeSender(row, format: format, draftPrefix: draftPrefix, muted: muted)
        let line = makeLine(row, chips: chips, format: format, muted: muted, followUpReason: followUpReason)
        texts[row.id] = Entry(row: row, chips: chips, draftPrefix: draftPrefix, muted: muted,
                              followUpReason: followUpReason, sender: sender, line: line)
        return (sender, line)
    }

    private func makeSender(_ row: ThreadRow, format: ThreadRowFormatting, draftPrefix: Bool,
                            muted: Bool) -> NSAttributedString {
        let font = muted ? bodyFont : (Self.senderIsAlwaysStrong || row.isUnread ? strongFont : bodyFont)
        let nameColor = muted ? secondary : senderColor
        let text = NSMutableAttributedString()
        if draftPrefix {
            text.append(NSAttributedString(string: Self.draftWord, attributes: attributes(font, success)))
            text.append(NSAttributedString(string: " ", attributes: attributes(font, success)))
        }
        let sender = format.sender(row)
        text.append(NSAttributedString(string: sender.name, attributes: attributes(font, nameColor)))
        if let count = sender.count {
            text.append(NSAttributedString(string: " " + count, attributes: attributes(metaFont, tertiary)))
        }
        return text
    }

    private func makeLine(_ row: ThreadRow, chips: [ThreadRowChip], format: ThreadRowFormatting,
                          muted: Bool, followUpReason: String? = nil) -> NSAttributedString {
        let strong = row.isUnread && !muted ? unreadFont : bodyFont
        let line = NSMutableAttributedString()
        if Self.chipsAreFilled { appendFilledChips(chips, to: line) }
        if let subject = format.subject(row) {
            line.append(NSAttributedString(string: subject, attributes: attributes(strong, muted ? secondary : primary)))
        } else {
            line.append(NSAttributedString(string: Self.noSubject, attributes: attributes(bodyFont, tertiary)))
        }
        for chip in Self.chipsAreFilled ? [] : chips {
            gap(line, 8)
            switch chip.kind {
            case .overflow:
                line.append(NSAttributedString(string: chip.title, attributes: attributes(metaFont, tertiary)))
                continue
            case .important:
                dot("●", warning, into: line)
            case .vip:
                dot("★", warning, into: line)
            case .category:
                dot("○", tertiary, into: line)
            case .label:
                dot("●", chip.color.flatMap { ThemeColor(hex: $0)?.nsColor } ?? tertiary, into: line)
            }
            line.append(NSAttributedString(string: chip.title, attributes: attributes(metaFont, chip.isFallback ? tertiary : secondary)))
        }
        if let followUpReason, !followUpReason.isEmpty {
            gap(line, 8)
            sparkle(into: line)
            gap(line, 4)
            line.append(NSAttributedString(string: followUpReason,
                                           attributes: attributes(bodyFont, snippet, extra: [Self.dimRun: true])))
            return line
        }
        let text = format.snippet(row)
        let related = row.searchMatch == .related
        if related {
            gap(line, 8)
            sparkle(into: line)
        }
        if !text.isEmpty {
            gap(line, related ? 4 : 8)
            line.append(NSAttributedString(string: text, attributes: attributes(bodyFont, snippet, extra: [Self.dimRun: true])))
        }
        return line
    }

    private func sparkle(into text: NSMutableAttributedString) {
        guard let image = symbol(Self.relatedSymbol, color: ai) else { return }
        let height = metrics.indicatorSize
        let width = image.size.height > 0 ? (height * image.size.width / image.size.height).rounded() : height
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: ((bodyFont.capHeight - height) / 2).rounded(), width: width, height: height)
        let run = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        run.addAttributes(attributes(bodyFont, ai), range: NSRange(location: 0, length: run.length))
        text.append(run)
    }

    static let relatedSymbol = "sparkle"

    private func appendFilledChips(_ chips: [ThreadRowChip], to line: NSMutableAttributedString) {
        let shown = LabelChipRenderer.shown(chips, maximum: Self.maximumFilledChips)
        guard !shown.isEmpty else { return }
        for (index, chip) in shown.enumerated() {
            if index > 0 { gap(line, CGFloat(theme.space2)) }
            line.append(chipAttachment(chip.title, hue: chip.hue, muted: chip.muted))
        }
        gap(line, CGFloat(theme.space3))
    }

    private func chipAttachment(_ title: String, hue: LabelChipHue, muted: Bool = false) -> NSAttributedString {
        let chip = chips.image(title, hue: hue, muted: muted)
        let attachment = NSTextAttachment()
        attachment.image = chip.image
        attachment.bounds = NSRect(x: 0, y: -chip.baseline, width: chip.image.size.width, height: chip.image.size.height)
        let text = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        text.addAttributes([.baselineOffset: baseline, .paragraphStyle: truncating], range: NSRange(location: 0, length: text.length))
        return text
    }

    func chipBaseline(_ title: String, hue: LabelChipHue = .neutral, muted: Bool = false) -> CGFloat {
        chips.image(title, hue: hue, muted: muted).baseline
    }

    private func gap(_ text: NSMutableAttributedString, _ width: CGFloat) {
        text.append(NSAttributedString(string: " ", attributes: attributes(bodyFont, secondary, extra: [.kern: width - spaceWidth])))
    }

    private func dot(_ glyph: String, _ color: NSColor, into text: NSMutableAttributedString) {
        let offset = (metaFont.xHeight - chipDotFont.xHeight) / 2
        text.append(NSAttributedString(string: glyph, attributes: attributes(chipDotFont, color, extra: [.baselineOffset: baseline + offset])))
        text.append(NSAttributedString(string: " ", attributes: attributes(metaFont, color, extra: [.kern: 3 - metaSpaceWidth])))
    }

    private struct DateKey: Hashable {
        let date: Date
        let location: MailLocation
        let unread: Bool
        let day: Int
    }

    private var formattedDates: [DateKey: NSAttributedString] = [:]

    func dateText(for row: ThreadRow, location: MailLocation, format: ThreadRowFormatting, now: Date,
                  day: Int, muted: Bool = false) -> NSAttributedString {
        let upcoming: Date? = switch location {
        case .system(.snoozed): row.snoozedUntil
        case .system(.reminders): row.reminderAt
        case .system(.scheduled): row.scheduledSendAt
        default: nil
        }
        var keyDate = upcoming ?? row.lastMessageAt
        if upcoming == nil, let dateDay = format.calendar.ordinality(of: .day, in: .era, for: keyDate), dateDay != day {
            keyDate = Date(timeIntervalSinceReferenceDate: Double(dateDay) * 86_400)
        }
        let key = DateKey(date: keyDate, location: upcoming == nil ? .system(.inbox) : location,
                          unread: row.isUnread && !muted, day: day)
        if let cached = formattedDates[key] { return cached }
        let column = format.dateColumn(row, location: location, now: now)
        let value = date(column.text, unread: row.isUnread && !muted, upcoming: column.isUpcoming)
        if formattedDates.count > 8_192 { retire(&formattedDates) }
        formattedDates[key] = value
        return value
    }

    func date(_ text: String, unread: Bool, upcoming: Bool) -> NSAttributedString {
        let key = "\(unread ? 1 : 0)\(upcoming ? 1 : 0)\(text)"
        if let cached = dates[key] { return cached }
        let color = upcoming ? warning : (unread ? theme.component.row.dateUnread.nsColor : theme.component.row.date.nsColor)
        var extra: [NSAttributedString.Key: Any] = [.paragraphStyle: rightAligned]
        if !upcoming, !unread { extra[Self.dimRun] = true }
        let value = NSAttributedString(string: text, attributes: attributes(metaFont, color, extra: extra))
        if dates.count > 512 { dates.removeAll(keepingCapacity: true) }
        dates[key] = value
        return value
    }

    struct Columns: Equatable {
        var dotCenterX: CGFloat
        var sender: ClosedRange<CGFloat>
        var subject: ClosedRange<CGFloat>
        var indicators: ClosedRange<CGFloat>
        var date: ClosedRange<CGFloat>
    }

    struct Metrics: Equatable {
        var leading: CGFloat
        var trailing: CGFloat
        var dotCenterX: CGFloat
        var senderGap: CGFloat
        var columnGap: CGFloat
        var senderMin: CGFloat
        var senderMax: CGFloat
        var senderPct: CGFloat
        var indicatorWidth: CGFloat
        var indicatorSize: CGFloat
        var dateWidth: CGFloat
        var buttonGap: CGFloat
        var buttonGlyph: CGFloat
    }

    static func openness(_ theme: ThemeTokens) -> CGFloat {
        let span = theme.densityComfortableRow - theme.densityDefaultRow
        guard span > 0 else { return 0 }
        return CGFloat(min(1, max(0, (theme.rowHeight - theme.densityDefaultRow) / span)))
    }

    static func typeScale(_ theme: ThemeTokens) -> CGFloat {
        guard theme.typeBody.size > 0 else { return 1 }
        return 1 + openness(theme) * CGFloat(max(0, theme.typeHeadline.size / theme.typeBody.size - 1))
    }

    static func densityTyped(_ theme: ThemeTokens) -> ThemeTokens {
        let scale = Double(typeScale(theme))
        guard scale != 1 else { return theme }
        var tokens = theme
        func scaled(_ style: inout TypeStyle) {
            style.size = (style.size * scale * 2).rounded() / 2
            style.lineHeight = (style.lineHeight * scale).rounded(.down)
        }
        scaled(&tokens.typeBody)
        scaled(&tokens.typeBodyStrong)
        scaled(&tokens.typeMeta)
        scaled(&tokens.typeCaption)
        return tokens
    }

    static func metrics(_ theme: ThemeTokens) -> Metrics {
        let row = theme.component.row
        let open = openness(theme)
        let type = typeScale(theme)
        let padding = CGFloat(row.paddingX), gutter = CGFloat(row.dotGutter), gap = CGFloat(row.columnGap)
        let leading = padding * (1 + open)
        return Metrics(leading: leading, trailing: padding * (1 + open / 2), dotCenterX: leading - gutter / 2 * (1 + open),
                       senderGap: gap * (1 + open), columnGap: gap,
                       senderMin: (CGFloat(row.senderMin) * type).rounded(), senderMax: CGFloat(row.senderMax),
                       senderPct: CGFloat(row.senderPct),
                       indicatorWidth: (CGFloat(row.indicatorWidth) * type).rounded(), indicatorSize: (12 * type).rounded(),
                       dateWidth: (CGFloat(row.dateWidth) * type).rounded(),
                       buttonGap: 4 + open * CGFloat(theme.space3), buttonGlyph: (14 * type).rounded())
    }

    func columns(width: CGFloat) -> Columns { Self.columns(width: width, metrics: metrics) }

    static func columns(width: CGFloat, metrics m: Metrics) -> Columns {
        let senderWidth = min(max(m.senderMin, (width * m.senderPct).rounded()), m.senderMax)
        let senderStart = m.leading
        let subjectStart = senderStart + senderWidth + m.senderGap
        let dateEnd = width - m.trailing
        let dateStart = dateEnd - m.dateWidth
        let indicatorStart = dateStart - m.indicatorWidth
        let subjectEnd = max(subjectStart, indicatorStart - m.columnGap)
        return Columns(dotCenterX: m.dotCenterX, sender: senderStart...(senderStart + senderWidth),
                       subject: subjectStart...subjectEnd, indicators: indicatorStart...dateStart, date: dateStart...dateEnd)
    }
}

// Handed to a background thread to be freed; nothing reads it afterwards, so the non-Sendable contents are safe
private final class Retired: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}
