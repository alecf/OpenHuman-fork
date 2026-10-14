import Foundation

public enum TokenSource: Sendable, Hashable {
    case value(TokenValue)
    case reference(String)
}

public struct TypographySpec: Sendable, Hashable {
    public var size: Double?
    public var lineHeight: Double?
    public var weight: Int?
    public var trackingEm: Double?
    public var tabularNumerals: Bool?
    public var role: FontRole?

    public init(size: Double? = nil, lineHeight: Double? = nil, weight: Int? = nil, trackingEm: Double? = nil,
                tabularNumerals: Bool? = nil, role: FontRole? = nil) {
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.trackingEm = trackingEm
        self.tabularNumerals = tabularNumerals
        self.role = role
    }

    func merged(over base: TypographySpec) -> TypographySpec {
        TypographySpec(size: size ?? base.size, lineHeight: lineHeight ?? base.lineHeight, weight: weight ?? base.weight,
                       trackingEm: trackingEm ?? base.trackingEm, tabularNumerals: tabularNumerals ?? base.tabularNumerals,
                       role: role ?? base.role)
    }
}

public struct ThemeFile: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case theme = "openhuman-theme"
        case accent = "openhuman-accent"
    }

    public enum Appearance: String, Sendable, Hashable {
        case light, dark, any
    }

    public var kind: Kind
    public var formatVersion: Int
    public var id: String
    public var name: String
    public var author: String?
    public var appearance: Appearance
    public var extends: String?
    public var defaultAccent: String?
    public var primitives: [String: ThemeColor]
    public var tokens: [String: TokenSource]
    public var typography: [String: TypographySpec]
    public var accent: [ThemeAppearance: [String: TokenSource]]

    public init(kind: Kind, formatVersion: Int = 1, id: String, name: String, author: String? = nil,
                appearance: Appearance = .any, extends: String? = nil, defaultAccent: String? = nil,
                primitives: [String: ThemeColor] = [:], tokens: [String: TokenSource] = [:],
                typography: [String: TypographySpec] = [:], accent: [ThemeAppearance: [String: TokenSource]] = [:]) {
        self.kind = kind
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.author = author
        self.appearance = appearance
        self.extends = extends
        self.defaultAccent = defaultAccent
        self.primitives = primitives
        self.tokens = tokens
        self.typography = typography
        self.accent = accent
    }

    public var accentShortID: String { id.split(separator: ".").last.map(String.init) ?? id }

    public static func isReserved(_ id: String) -> Bool { id == "openhuman" || id.hasPrefix("openhuman.") }

    public static func isValidID(_ id: String) -> Bool {
        let segments = id.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(segments.count), id.utf8.count <= 64 else { return false }
        for (index, segment) in segments.enumerated() {
            guard !segment.isEmpty else { return false }
            for byte in segment.utf8 {
                let ok = (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                    || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || (index > 0 && byte == UInt8(ascii: "-"))
                guard ok else { return false }
            }
        }
        return true
    }

    public static func isValidAccentShortID(_ id: String) -> Bool {
        guard (1...32).contains(id.utf8.count), let first = id.utf8.first, first != UInt8(ascii: "-") else { return false }
        return id.utf8.allSatisfy { ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || $0 == UInt8(ascii: "-") }
    }
}
