import Foundation

@dynamicMemberLookup
public struct ResolvedTheme: Sendable, Hashable {
    public let themeID: String
    public let themeName: String
    public let accentID: String
    public let appearance: ThemeAppearance
    public let tokens: ThemeTokens
    public let emailColors: EmailColors
    public let issues: [ThemeIssue]

    public init(themeID: String, themeName: String, accentID: String, appearance: ThemeAppearance, tokens: ThemeTokens,
                emailColors: EmailColors? = nil, issues: [ThemeIssue] = []) {
        self.themeID = themeID
        self.themeName = themeName
        self.accentID = accentID
        self.appearance = appearance
        self.tokens = tokens
        self.emailColors = emailColors ?? tokens.readerEmailColors
        self.issues = issues
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<ThemeTokens, T>) -> T { tokens[keyPath: keyPath] }

    public func color(_ token: ColorToken) -> ThemeColor { tokens.color(token) }
    public func type(_ token: TypeToken) -> TypeStyle { tokens.type(token) }

    public var readerCSS: String { ReaderCSS.stylesheet(for: self) }

    public func replacingMissingFonts(isInstalled: (String) -> Bool) -> ResolvedTheme {
        var tokens = self.tokens
        var notes: [ThemeIssue] = []
        for (path, keyPath) in [("typography.family.ui", \ThemeTokens.fontFamilyUI), ("typography.family.reader", \.fontFamilyReader),
                                ("typography.family.mono", \.fontFamilyMono)] {
            guard case .named(let name) = tokens[keyPath: keyPath], !isInstalled(name) else { continue }
            tokens[keyPath: keyPath] = keyPath == \ThemeTokens.fontFamilyMono ? .systemMono : .system
            notes.append(.warning(.fontMissing, path, "the font \(name) is not installed; using the system font"))
        }
        guard !notes.isEmpty else { return self }
        tokens.bakeFontFamilies()
        return ResolvedTheme(themeID: themeID, themeName: themeName, accentID: accentID, appearance: appearance, tokens: tokens,
                             emailColors: emailColors, issues: issues + notes)
    }

    public static let light = ThemeLibrary.builtIn.resolve(themeID: BuiltinThemeID.light, appearance: .light)
    public static let dark = ThemeLibrary.builtIn.resolve(themeID: BuiltinThemeID.dark, appearance: .dark)
}

extension ThemeTokens {
    public static var light: ThemeTokens { BuiltinTables.shared.light }
    public static var dark: ThemeTokens { BuiltinTables.shared.dark }
    public static var paper: ThemeTokens { BuiltinTables.shared.paper }
    public static var midnight: ThemeTokens { BuiltinTables.shared.midnight }

    public var rowHeight: Double {
        switch density {
        case .compact: densityCompactRow
        case .default: densityDefaultRow
        case .comfortable: densityComfortableRow
        }
    }

    public var splitRowHeight: Double {
        switch density {
        case .compact: densityCompactSplitRow
        case .default: densityDefaultSplitRow
        case .comfortable: densityComfortableSplitRow
        }
    }

    public var space: [Double] { [space0, space1, space2, space3, space4, space5, space6, space7, space8, space9, space10, space11] }

    public var avatarFills: [ThemeColor] { Self.avatarPalette }

    public static let avatarPalette: [ThemeColor] = [
        ThemeColor(r8: 0x25, g8: 0x63, b8: 0xEB), ThemeColor(r8: 0x6D, g8: 0x3F, b8: 0xD9),
        ThemeColor(r8: 0x0F, g8: 0x76, b8: 0x6E), ThemeColor(r8: 0xA8, g8: 0x4F, b8: 0x08),
        ThemeColor(r8: 0xBE, g8: 0x18, b8: 0x5D), ThemeColor(r8: 0x4D, g8: 0x74, b8: 0x17),
        ThemeColor(r8: 0x47, g8: 0x55, b8: 0x69), ThemeColor(r8: 0xC2, g8: 0x41, b8: 0x0C),
    ]

    public func avatarFill(for email: String) -> ThemeColor {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in email.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Self.avatarPalette[Int(hash % UInt64(Self.avatarPalette.count))]
    }

    mutating func bakeFontFamilies() {
        let families: [FontRole: FontFamily] = [.ui: fontFamilyUI, .reader: fontFamilyReader, .mono: fontFamilyMono]
        forEachTypography { style in style.family = families[style.role] ?? .system }
    }
}

final class BuiltinTables: Sendable {
    static let shared = BuiltinTables()

    let light: ThemeTokens
    let dark: ThemeTokens
    let paper: ThemeTokens
    let midnight: ThemeTokens

    private init() {
        let library = ThemeLibrary.builtInFiles()
        func table(_ id: String, _ appearance: ThemeAppearance) -> ThemeTokens {
            guard let tokens = library.completeTokens(themeID: id, accentID: BuiltinThemeID.defaultAccent, appearance: appearance) else {
                preconditionFailure("built-in theme \(id) does not resolve every registry token")
            }
            return tokens
        }
        light = table(BuiltinThemeID.light, .light)
        dark = table(BuiltinThemeID.dark, .dark)
        paper = table(BuiltinThemeID.paper, .light)
        midnight = table(BuiltinThemeID.midnight, .dark)
    }
}
