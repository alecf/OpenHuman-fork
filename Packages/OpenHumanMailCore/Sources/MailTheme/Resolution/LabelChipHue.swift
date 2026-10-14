import Foundation

public enum LabelChipHue: String, Sendable, Hashable, CaseIterable {
    case rose, coral, tangerine, amber, green, teal, sky, lavender, neutral

    public static let named: [LabelChipHue] = [.rose, .coral, .tangerine, .amber, .green, .teal, .sky, .lavender]

    public static let minimumSaturation = 0.18

    private static let ranges: [(start: Double, hue: LabelChipHue)] = [
        (0, .coral), (20, .tangerine), (40, .amber), (65, .green), (160, .teal), (195, .sky), (250, .lavender),
        (300, .rose), (345, .coral),
    ]

    public static func nearest(toHex hex: String) -> LabelChipHue? {
        guard let color = ThemeColor(hex: hex) else { return nil }
        let (r, g, b) = (color.red, color.green, color.blue)
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        let lightness = (high + low) / 2
        let divisor = 1 - abs(2 * lightness - 1)
        let saturation = divisor <= 0 ? 0 : delta / divisor
        guard delta > 0, saturation >= minimumSaturation else { return .neutral }
        var degrees: Double
        if high == r {
            degrees = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if high == g {
            degrees = 60 * ((b - r) / delta + 2)
        } else {
            degrees = 60 * ((r - g) / delta + 4)
        }
        degrees = (degrees * 1e9).rounded() / 1e9
        return nearest(toHue: degrees)
    }

    public static func nearest(toHue degrees: Double) -> LabelChipHue {
        var wrapped = degrees.truncatingRemainder(dividingBy: 360)
        if wrapped < 0 { wrapped += 360 }
        return ranges.last { wrapped >= $0.start }?.hue ?? .coral
    }

    public static func forName(_ title: String) -> LabelChipHue {
        var hash: UInt32 = 0x811C_9DC5
        for byte in title.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return named[Int(hash % UInt32(named.count))]
    }

    private static let categories: [String: LabelChipHue] = [
        "marketing": .coral, "promotions": .coral, "news": .amber, "forums": .amber, "pitch": .lavender,
        "social": .sky, "invoice": .green, "travel": .tangerine, "meeting": .teal, "updates": .teal,
        "respond": .rose, "personal": .rose, "waiting": .neutral,
    ]

    public static func category(_ title: String) -> LabelChipHue {
        categories[title.lowercased()] ?? forName(title)
    }
}

extension ThemeTokens {
    public func labelChip(_ hue: LabelChipHue) -> (bg: ThemeColor, text: ThemeColor) {
        let chip = component.labelChip
        switch hue {
        case .rose: return (chip.roseBg, chip.roseText)
        case .coral: return (chip.coralBg, chip.coralText)
        case .tangerine: return (chip.tangerineBg, chip.tangerineText)
        case .amber: return (chip.amberBg, chip.amberText)
        case .green: return (chip.greenBg, chip.greenText)
        case .teal: return (chip.tealBg, chip.tealText)
        case .sky: return (chip.skyBg, chip.skyText)
        case .lavender: return (chip.lavenderBg, chip.lavenderText)
        case .neutral: return (component.row.chipBg, component.row.chipText)
        }
    }
}
