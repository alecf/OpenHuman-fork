import Foundation

public struct ThemeColor: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(r8: UInt8, g8: UInt8, b8: UInt8, alpha: Double = 1) {
        self.init(red: Double(r8) / 255, green: Double(g8) / 255, blue: Double(b8) / 255, alpha: alpha)
    }

    public init?(hex: String) {
        guard let parsed = ThemeColor.parseHex(Substring(hex)) else { return nil }
        self = parsed
    }

    public init?(literal: String) {
        if literal.hasPrefix("#") {
            guard let parsed = ThemeColor.parseHex(Substring(literal)) else { return nil }
            self = parsed
        } else if let parsed = ThemeColor.parseRGBA(literal) {
            self = parsed
        } else {
            return nil
        }
    }

    public var css: String {
        if alpha >= 1 {
            return String(format: "#%02x%02x%02x", Self.byte(red), Self.byte(green), Self.byte(blue))
        }
        return "rgba(\(Self.byte(red)),\(Self.byte(green)),\(Self.byte(blue)),\(String(format: "%.3f", alpha)))"
    }

    public var literal: String {
        if alpha >= 1 {
            return String(format: "#%02X%02X%02X", Self.byte(red), Self.byte(green), Self.byte(blue))
        }
        let short = Self.shortNumber(alpha)
        let a8 = alpha * 255
        if short.count > 6, abs(a8 - a8.rounded()) < 1e-9 {
            return String(format: "#%02X%02X%02X%02X", Self.byte(red), Self.byte(green), Self.byte(blue), Int(a8.rounded()))
        }
        return "rgba(\(Self.byte(red)),\(Self.byte(green)),\(Self.byte(blue)),\(short))"
    }

    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func composited(over background: ThemeColor) -> ThemeColor {
        guard alpha < 1 else { return self }
        let a = max(0, min(1, alpha))
        return ThemeColor(red: red * a + background.red * (1 - a), green: green * a + background.green * (1 - a),
                          blue: blue * a + background.blue * (1 - a), alpha: 1)
    }

    public func contrastRatio(on background: ThemeColor) -> Double {
        let bg = background.alpha < 1 ? background.composited(over: ThemeColor(red: 1, green: 1, blue: 1)) : background
        let fg = composited(over: bg)
        let (l1, l2) = (fg.relativeLuminance, bg.relativeLuminance)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    static func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }

    static func shortNumber(_ v: Double) -> String {
        if v.isFinite, abs(v) < 1e15, v == v.rounded() { return String(Int(v)) }
        return "\(v)"
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func parseHex(_ text: Substring) -> ThemeColor? {
        let bytes = Array(text.utf8)
        guard bytes.first == UInt8(ascii: "#"), bytes.count == 7 || bytes.count == 9 else { return nil }
        var channels: [UInt8] = []
        var i = 1
        while i < bytes.count {
            guard let hi = hexValue(bytes[i]), let lo = hexValue(bytes[i + 1]) else { return nil }
            channels.append(hi << 4 | lo)
            i += 2
        }
        let alpha = channels.count == 4 ? Double(channels[3]) / 255 : 1
        return ThemeColor(r8: channels[0], g8: channels[1], b8: channels[2], alpha: alpha)
    }

    private static func parseRGBA(_ text: String) -> ThemeColor? {
        guard text.hasPrefix("rgba("), text.hasSuffix(")"), text.utf8.count <= 40 else { return nil }
        let inner = text.dropFirst(5).dropLast()
        let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var channels: [UInt8] = []
        for (index, raw) in parts.enumerated() {
            let part = index == 0 ? raw[...] : raw.drop(while: { $0 == " " })
            if index < 3 {
                guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let value = Int(part), value <= 255 else { return nil }
                channels.append(UInt8(value))
            } else {
                guard let alpha = parseUnitDecimal(part) else { return nil }
                return ThemeColor(r8: channels[0], g8: channels[1], b8: channels[2], alpha: alpha)
            }
        }
        return nil
    }

    static func parseUnitDecimal(_ text: Substring) -> Double? {
        guard (1...8).contains(text.count), text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              text.filter({ $0 == "." }).count <= 1, text != ".", let value = Double(text),
              (0...1).contains(value) else { return nil }
        return value
    }
}
