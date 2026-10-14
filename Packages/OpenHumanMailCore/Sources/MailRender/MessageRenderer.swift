import Foundation
import MailModel
import MailTheme

public struct RenderedMessage: Sendable, Equatable {
    public let html: String
    public let hasRemoteContent: Bool
    public let blockedCount: Int
    public let trackerCount: Int
    public let hasQuotedText: Bool
    public let contentHash: UInt64
    public let textLength: Int
    public let tier: DarkModeTier
    public let colorTreatment: ColorTreatment
    public let colorScheme: ReaderCSS.ColorScheme
    public let suspiciousLinks: [SuspiciousLink]
    public let inlineContentIDs: [String]
    public let trackerDomains: [String]
    public let isTruncated: Bool

    public func suspiciousLink(for url: URL) -> SuspiciousLink? {
        suspiciousLinks.first { $0.matches(url) }
    }
}

public enum RenderedBody: Sendable, Equatable {
    case html(RenderedMessage)
    case plain(PlainTextDocument)
    case empty
}

public struct RenderContext: Sendable, Hashable, Codable {
    public var allowRemoteImages: Bool
    public var colorOverride: ColorOverride?
    public var textFormat: PlainTextFormat
    public var keepOriginalSpacing: Bool

    public init(allowRemoteImages: Bool = false, colorOverride: ColorOverride? = nil, textFormat: PlainTextFormat = .fixed,
                keepOriginalSpacing: Bool = false) {
        self.keepOriginalSpacing = keepOriginalSpacing
        self.allowRemoteImages = allowRemoteImages
        self.colorOverride = colorOverride
        self.textFormat = textFormat
    }
}

public struct RenderCacheKey: Sendable, Hashable {
    public let message: MessageKey
    public let sanitizerVersion: Int
    public let themeFingerprint: UInt64
    public let appearance: ThemeAppearance
    public let emailColors: EmailColors
    public let context: RenderContext

    public var stableName: String {
        let override = context.colorOverride?.rawValue ?? "none"
        let format: String
        switch context.textFormat {
        case .fixed: format = "fixed"
        case .flowed(let delSp): format = delSp ? "flowed-delsp" : "flowed"
        }
        return "\(message.account.rawValue)-\(message.rowID)-v\(sanitizerVersion)-\(String(themeFingerprint, radix: 16))-"
            + "\(appearance.rawValue)-\(emailColors.rawValue)-\(context.allowRemoteImages ? "img" : "noimg")-\(override)-\(format)"
            + (context.keepOriginalSpacing ? "-orig" : "")
    }
}

public struct MessageRenderer: Sendable {
    public var theme: ThemeTokens
    public var options: SanitizerOptions
    public var appearance: ThemeAppearance
    public var emailColors: EmailColors
    public var underlineLinks: Bool

    public init(theme: ThemeTokens = .light, options: SanitizerOptions = SanitizerOptions(),
                appearance: ThemeAppearance = .light, emailColors: EmailColors? = nil, underlineLinks: Bool = false) {
        self.theme = theme
        self.options = options
        self.appearance = appearance
        self.emailColors = emailColors ?? theme.readerEmailColors
        self.underlineLinks = underlineLinks
    }

    public init(theme: ResolvedTheme, options: SanitizerOptions = SanitizerOptions()) {
        self.init(theme: theme.tokens, options: options, appearance: theme.appearance, emailColors: theme.emailColors,
                  underlineLinks: theme.accentID == "graphite")
    }

    public func render(_ content: MessageContent) -> RenderedBody {
        render(content, context: RenderContext(allowRemoteImages: options.allowRemoteImages))
    }

    public func render(_ content: MessageContent, context: RenderContext) -> RenderedBody {
        if let html = content.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var options = self.options
            options.allowRemoteImages = context.allowRemoteImages
            options.mode = .reader
            options.trimBlankSpace = !context.keepOriginalSpacing
            let colors = ColorContext(theme: theme, appearance: appearance, emailColors: emailColors,
                                      override: context.colorOverride)
            let sanitized = HTMLSanitizer.sanitize(html, options: options, colors: colors)
            let document = ReaderDocument.make(sanitized, theme: theme, allowRemoteImages: context.allowRemoteImages,
                                               appearance: appearance, underlineLinks: underlineLinks,
                                               keepOriginalSpacing: context.keepOriginalSpacing)
            return .html(RenderedMessage(
                html: document,
                hasRemoteContent: sanitized.remoteReferences - sanitized.trackerReferences > 0,
                blockedCount: sanitized.blockedRemote, trackerCount: sanitized.trackers,
                hasQuotedText: sanitized.hasQuotedText, contentHash: Self.fnv1a(document),
                textLength: sanitized.textLength, tier: sanitized.tier, colorTreatment: sanitized.treatment,
                colorScheme: DarkModePolicy.colorScheme(for: sanitized.treatment, appearance: appearance),
                suspiciousLinks: sanitized.suspiciousLinks, inlineContentIDs: sanitized.inlineContentIDs,
                trackerDomains: sanitized.trackerDomains, isTruncated: sanitized.isTruncated))
        }
        if let text = content.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .plain(PlainTextDocument.parse(text, format: context.textFormat, maxBytes: options.limits.maxInputBytes))
        }
        return .empty
    }

    public func cacheKey(for message: MessageKey, context: RenderContext) -> RenderCacheKey {
        RenderCacheKey(message: message, sanitizerVersion: HTMLSanitizer.version * 1000 + TrackerList.version,
                       themeFingerprint: themeFingerprint, appearance: appearance, emailColors: emailColors,
                       context: context)
    }

    public var themeFingerprint: UInt64 {
        Self.fnv1a(ReaderCSS.stylesheet(tokens: theme, colorScheme: appearance == .dark ? .dark : .light,
                                        underlineLinks: underlineLinks) + ReaderDocument.structureCSS(theme: theme))
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
