import AppKit
import MailFeatures
import MailTheme

@MainActor
final class LabelChipRenderer {
    let theme: ThemeTokens
    let chipType: TypeStyle
    let chipFont: NSFont
    static let minimumTextSize: Double = 11
    var chipHeight: CGFloat { CGFloat(chipType.lineHeight + theme.space1) }

    private struct Key: Hashable {
        let title: String
        let hue: LabelChipHue
        let muted: Bool
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
    }

    func colors(hue: LabelChipHue, muted: Bool) -> (fill: ThemeColor, ink: ThemeColor) {
        if muted { return (theme.component.row.chipBg, theme.textTertiary) }
        let pair = theme.labelChip(hue)
        return (pair.bg, pair.text)
    }

    func image(_ title: String, hue: LabelChipHue, muted: Bool) -> (image: NSImage, baseline: CGFloat) {
        let key = Key(title: title, hue: hue, muted: muted)
        if let cached = images[key] { return cached }
        let made = make(title, hue: hue, muted: muted)
        images[key] = made
        keys[ObjectIdentifier(made.image)] = key
        return made
    }

    static func shown(_ chips: [ThreadRowChip], maximum: Int) -> [(title: String, hue: LabelChipHue, muted: Bool)] {
        let named = chips.filter { $0.kind != .overflow }
        guard !named.isEmpty else { return [] }
        let overflow = chips.first { $0.kind == .overflow }.flatMap { Int($0.title.dropFirst()) } ?? 0
        let visible = named.prefix(max(0, maximum))
        let hidden = named.count - visible.count + overflow
        var result = visible.map {
            (title: $0.kind == .returned ? $0.title : $0.title.localizedLowercase, hue: $0.hue, muted: $0.isFallback)
        }
        if hidden > 0 { result.append((title: "+\(hidden)", hue: .neutral, muted: false)) }
        return result
    }

    private func make(_ title: String, hue: LabelChipHue, muted: Bool) -> (image: NSImage, baseline: CGFloat) {
        let colors = colors(hue: hue, muted: muted)
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
                  let key = keys[ObjectIdentifier(shown)], key.hue != .neutral else { return }
            let neutral = NSTextAttachment()
            neutral.image = image(key.title, hue: .neutral, muted: key.muted).image
            neutral.bounds = attachment.bounds
            variant.addAttribute(.attachment, value: neutral, range: range)
            swapped = true
        }
        let result: NSAttributedString = swapped ? variant : line
        if checkedLines.count >= 512 { checkedLines.removeAll(keepingCapacity: true) }
        checkedLines[id] = (line, result)
        return result
    }
}
