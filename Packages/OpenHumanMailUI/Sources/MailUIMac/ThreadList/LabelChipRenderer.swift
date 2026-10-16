import AppKit
import MailFeatures
import MailTheme

@MainActor
final class LabelChipRenderer {
    let theme: ThemeTokens
    let chipType: TypeStyle
    let chipFont: NSFont
    let checkedFill: ThemeColor
    static let minimumTextSize: Double = 11
    var chipHeight: CGFloat { CGFloat(chipType.lineHeight + theme.space1) }

    private struct Key: Hashable {
        let title: String
        let hue: LabelChipHue
        let muted: Bool
        let checked: Bool
    }

    private var images: [Key: (image: NSImage, baseline: CGFloat)] = [:]
    private var keys: [ObjectIdentifier: Key] = [:]
    private var checkedLines: [ObjectIdentifier: (source: NSAttributedString, variant: NSAttributedString)] = [:]

    init(theme: ThemeTokens) {
        self.theme = theme
        var type = theme.typeCaption
        if type.size < Self.minimumTextSize, theme.typeMeta.size > type.size {
            type = theme.typeMeta
            type.weight = theme.typeCaption.weight
        }
        chipType = type
        chipFont = type.font
        checkedFill = Self.checkedFill(theme)
    }

    // A grey chip all but vanishes on a light checked row; the window surface stands out more
    static func checkedFill(_ theme: ThemeTokens) -> ThemeColor {
        let plate = theme.listCheckedFill, chip = theme.component.row.chipBg
        let window = theme.bgWindow
        guard window.relativeLuminance > plate.relativeLuminance,
              window.contrastRatio(on: plate) > chip.composited(over: plate).contrastRatio(on: plate) else { return chip }
        return window
    }

    func colors(hue: LabelChipHue, muted: Bool, checked: Bool = false) -> (fill: ThemeColor, ink: ThemeColor) {
        if checked { return (checkedFill, muted ? theme.textTertiary : theme.component.row.chipText) }
        if muted { return (theme.component.row.chipBg, theme.textTertiary) }
        let pair = theme.labelChip(hue)
        return (pair.bg, pair.text)
    }

    func image(_ title: String, hue: LabelChipHue, muted: Bool, checked: Bool = false) -> (image: NSImage, baseline: CGFloat) {
        let onWindow = checked && checkedFill != theme.component.row.chipBg
        let key = Key(title: title, hue: checked ? .neutral : hue, muted: muted, checked: onWindow)
        if let cached = images[key] { return cached }
        let made = make(title, colors: colors(hue: key.hue, muted: muted, checked: onWindow))
        images[key] = made
        keys[ObjectIdentifier(made.image)] = key
        return made
    }

    static func counts(_ chips: [ThreadRowChip], maximum: Int) -> (visible: Int, hidden: Int) {
        let named = chips.filter { $0.kind != .overflow }
        guard !named.isEmpty else { return (0, 0) }
        let overflow = chips.first { $0.kind == .overflow }.flatMap { Int($0.title.dropFirst()) } ?? 0
        let visible = min(named.count, max(0, maximum))
        return (visible, named.count - visible + overflow)
    }

    static func shown(_ chips: [ThreadRowChip], maximum: Int) -> [(title: String, hue: LabelChipHue, muted: Bool)] {
        let (visible, hidden) = counts(chips, maximum: maximum)
        guard visible > 0 || hidden > 0 else { return [] }
        var result = chips.filter { $0.kind != .overflow }.prefix(visible).map {
            (title: $0.kind == .returned || $0.kind == .gmailImportant ? $0.title : $0.title.localizedLowercase,
             hue: $0.hue, muted: $0.isQuiet)
        }
        if hidden > 0 { result.append(overflow(hidden)) }
        return result
    }

    static func overflow(_ count: Int) -> (title: String, hue: LabelChipHue, muted: Bool) {
        (title: "+\(count)", hue: .neutral, muted: false)
    }

    private func make(_ title: String, colors: (fill: ThemeColor, ink: ThemeColor)) -> (image: NSImage, baseline: CGFloat) {
        let fill = colors.fill.nsColor, font = chipFont
        let radius = CGFloat(theme.component.row.chipRadius)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.ink.nsColor]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let paddingX = CGFloat(theme.space2 + theme.space1)
        let size = NSSize(width: (textSize.width + 2 * paddingX).rounded(.up), height: chipHeight)
        let textY = ((size.height - textSize.height) / 2).rounded()
        let image = NSImage(size: size, flipped: false) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            (title as NSString).draw(at: NSPoint(x: paddingX, y: textY), withAttributes: attributes)
            return true
        }
        return (image, (textY - font.descender).rounded())
    }

    func onChecked(_ line: NSAttributedString) -> NSAttributedString {
        let id = ObjectIdentifier(line)
        if let hit = checkedLines[id], hit.source === line { return hit.variant }
        let variant = NSMutableAttributedString(attributedString: line)
        var swapped = false
        line.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let shown = attachment.image,
                  let key = keys[ObjectIdentifier(shown)] else { return }
            let checked = image(key.title, hue: key.hue, muted: key.muted, checked: true).image
            guard checked !== shown else { return }
            let replacement = NSTextAttachment()
            replacement.image = checked
            replacement.bounds = attachment.bounds
            variant.addAttribute(.attachment, value: replacement, range: range)
            swapped = true
        }
        let result: NSAttributedString = swapped ? variant : line
        if checkedLines.count >= 512 { checkedLines.removeAll(keepingCapacity: true) }
        checkedLines[id] = (line, result)
        return result
    }
}
