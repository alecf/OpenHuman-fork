import Foundation
import MailTheme

public enum ReaderDocument {
    public static func contentSecurityPolicy(allowRemoteImages: Bool) -> String {
        let images = allowRemoteImages ? "ohcid: data: https: http:" : "ohcid: data:"
        return "default-src 'none'; img-src \(images); style-src 'unsafe-inline'; font-src data:; media-src 'none'; "
            + "frame-src 'none'; form-action 'none'; base-uri 'none'"
    }

    // Why: GrayText is translucent in WebKit (about 2:1 on white), so secondary text is a color-mix of CanvasText
    public static func structureCSS(theme: ThemeTokens) -> String {
        let inset = Int(theme.space5.rounded())
        return """
        @media screen { html { overflow-y: hidden; } }
        #oh-root { display: flow-root; }
        .oh-body { display: flow-root; }
        :where(.oh-body > :first-child, .oh-body > :first-child > :first-child) { margin-top: 0; }
        :where(.oh-original) { color-scheme: light; color: CanvasText; --oh-text: CanvasText; \
        --oh-text-secondary: color-mix(in srgb, CanvasText 62%, Canvas); --oh-link: LinkText; \
        --oh-quote: color-mix(in srgb, CanvasText 45%, Canvas); --oh-sunken: ButtonFace; }
        .oh-body.oh-card, .oh-body.oh-paper { padding: \(inset)px !important; }
        .oh-paper { background: var(--oh-card-bg); border-radius: var(--oh-card-radius); }
        a:not([href]) { color: inherit; text-decoration: none; }
        details.oh-quoted > summary { color: var(--oh-text-secondary); font-size: 10px; line-height: 16px; \
        text-align: center; letter-spacing: 1px; }
        details.oh-quoted > summary::-webkit-details-marker { display: none; }
        .oh-placeholder { color: var(--oh-text-secondary); }
        img.oh-blocked { background: var(--oh-sunken); }
        .oh-body:not(.oh-original-spacing) img.oh-blocked { max-height: 48px !important; }
        """
    }

    static func wrapperClasses(_ treatment: ColorTreatment, appearance: ThemeAppearance) -> [String] {
        guard treatment == .original else { return [] }
        return ["oh-original", appearance == .dark ? "oh-card" : "oh-paper"]
    }

    public static func make(_ sanitized: SanitizedHTML, theme: ThemeTokens, allowRemoteImages: Bool,
                            appearance: ThemeAppearance = .light, underlineLinks: Bool = false,
                            keepOriginalSpacing: Bool = false) -> String {
        let scheme = DarkModePolicy.colorScheme(for: sanitized.treatment, appearance: appearance)
        var html = "<!doctype html><html><head><meta charset=\"utf-8\">"
        html += "<meta http-equiv=\"Content-Security-Policy\" content=\""
        html += escapeAttribute(contentSecurityPolicy(allowRemoteImages: allowRemoteImages)) + "\">"
        html += "<meta name=\"referrer\" content=\"no-referrer\">"
        html += "<style id=\"oh-base\">" + ReaderCSS.stylesheet(tokens: theme, colorScheme: scheme, underlineLinks: underlineLinks)
            + "</style>"
        html += "<style id=\"oh-structure\">" + structureCSS(theme: theme) + "</style>"
        if !sanitized.bodyAttributeCSS.isEmpty {
            html += "<style id=\"oh-body-attributes\">" + sanitized.bodyAttributeCSS + "</style>"
        }
        for css in sanitized.headCSS { html += "<style>" + css + "</style>" }
        let classes = (["oh-body"] + (keepOriginalSpacing ? ["oh-original-spacing"] : []) + wrapperClasses(sanitized.treatment, appearance: appearance)
            + (sanitized.bodyClass.isEmpty ? [] : [sanitized.bodyClass])).joined(separator: " ")
        html += "</head><body><div id=\"oh-root\"><div class=\"" + escapeAttribute(classes) + "\"" + sanitized.bodyAttributes
            + ">" + sanitized.bodyHTML + "</div></div></body></html>"
        return html
    }
}
