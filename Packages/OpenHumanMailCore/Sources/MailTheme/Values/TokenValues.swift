import Foundation

public enum FontRole: String, Sendable, Hashable, CaseIterable {
    case ui, reader, mono
}

public enum FontFamily: Sendable, Hashable {
    case system
    case systemSerif
    case systemRounded
    case systemMono
    case named(String)

    public init?(token: String) {
        switch token {
        case "system": self = .system
        case "system-serif": self = .systemSerif
        case "system-rounded": self = .systemRounded
        case "system-mono": self = .systemMono
        default:
            guard FontFamily.isValidName(token) else { return nil }
            self = .named(token)
        }
    }

    public var token: String {
        switch self {
        case .system: "system"
        case .systemSerif: "system-serif"
        case .systemRounded: "system-rounded"
        case .systemMono: "system-mono"
        case .named(let name): name
        }
    }

    public var isSystem: Bool {
        if case .named = self { return false }
        return true
    }

    public static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.unicodeScalars.first,
              first.properties.isAlphabetic || ("0"..."9").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { s in
            s.isASCII && (("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s) || s == " " || s == "-")
        }
    }
}

public struct TypeStyle: Sendable, Hashable {
    public var size: Double
    public var lineHeight: Double
    public var weight: Int
    public var monospacedDigits: Bool
    public var trackingEm: Double
    public var role: FontRole
    public var family: FontFamily

    public init(size: Double, lineHeight: Double, weight: Int, monospacedDigits: Bool = false, trackingEm: Double = 0,
                role: FontRole = .ui, family: FontFamily = .system) {
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.monospacedDigits = monospacedDigits
        self.trackingEm = trackingEm
        self.role = role
        self.family = family
    }

    public var effectiveTracking: Double { family.isSystem ? 0 : trackingEm * size }
}

public struct ShadowLayer: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var blur: Double
    public var spread: Double
    public var color: ThemeColor

    public init(x: Double, y: Double, blur: Double, spread: Double, color: ThemeColor) {
        self.x = x
        self.y = y
        self.blur = blur
        self.spread = spread
        self.color = color
    }
}

public struct ThemeShadow: Sendable, Hashable {
    public var layers: [ShadowLayer]

    public init(layers: [ShadowLayer]) { self.layers = layers }

    public static let none = ThemeShadow(layers: [])

    public var css: String {
        guard !layers.isEmpty else { return "none" }
        func px(_ v: Double) -> String { v == 0 ? "0" : "\(ThemeColor.shortNumber(v))px" }
        return layers.map { "\(px($0.x)) \(px($0.y)) \(px($0.blur)) \(px($0.spread)) \($0.color.css)" }
            .joined(separator: ", ")
    }

    public var literal: String {
        layers.map { l in
            [l.x, l.y, l.blur, l.spread].map(ThemeColor.shortNumber).joined(separator: " ") + " " + l.color.literal
        }.joined(separator: ", ")
    }
}

public enum Easing: Sendable, Hashable {
    case none
    case linear
    case cubicBezier(Double, Double, Double, Double)

    public var css: String {
        switch self {
        case .none, .linear: "linear"
        case let .cubicBezier(a, b, c, d):
            "cubic-bezier(\([a, b, c, d].map(ThemeColor.shortNumber).joined(separator: ",")))"
        }
    }

    public var literal: String? {
        switch self {
        case .none: nil
        default: css
        }
    }
}

public struct ThemeMotion: Sendable, Hashable {
    public var durationMs: Double
    public var easing: Easing

    public init(durationMs: Double, easing: Easing = .none) {
        self.durationMs = durationMs
        self.easing = easing
    }

    public var seconds: Double { durationMs / 1000 }
}

public enum EmailColors: String, Sendable, Hashable, CaseIterable, Codable {
    case adaptWhenSafe, alwaysOriginal, alwaysAdapt
}

public enum ThemeDensity: String, Sendable, Hashable, CaseIterable, Codable {
    case compact, `default`, comfortable
}

public enum ThemeAppearance: String, Sendable, Hashable, CaseIterable, Codable {
    case light, dark
}

public enum AppearanceMode: String, Sendable, Hashable, CaseIterable, Codable {
    case light, dark, system

    public func effective(system: ThemeAppearance) -> ThemeAppearance {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: system
        }
    }
}

public enum TokenValue: Sendable, Hashable {
    case color(ThemeColor)
    case shadow(ThemeShadow)
    case number(Double)
    case typography(TypeStyle)
    case fontFamily(FontFamily)
    case motion(ThemeMotion)
    case duration(Double)
    case emailColors(EmailColors)
    case percent(Double)

    public var color: ThemeColor? { if case .color(let v) = self { v } else { nil } }
    public var shadow: ThemeShadow? { if case .shadow(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public var typography: TypeStyle? { if case .typography(let v) = self { v } else { nil } }
    public var fontFamily: FontFamily? { if case .fontFamily(let v) = self { v } else { nil } }
    public var motion: ThemeMotion? { if case .motion(let v) = self { v } else { nil } }
    public var duration: Double? { if case .duration(let v) = self { v } else { nil } }
    public var emailColors: EmailColors? { if case .emailColors(let v) = self { v } else { nil } }
    public var percent: Double? { if case .percent(let v) = self { v } else { nil } }
}
