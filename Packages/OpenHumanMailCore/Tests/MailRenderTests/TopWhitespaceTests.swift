import Foundation
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailRender

private func body(_ html: String, trim: Bool = true, remote: Bool = false) -> String {
    HTMLSanitizer.sanitize(html, options: SanitizerOptions(allowRemoteImages: remote, trimBlankSpace: trim)).bodyHTML
}

private let padding = String(repeating: "&#847;&zwnj;&nbsp;", count: 40)

@Suite struct TopWhitespaceTests {
    @Test func hiddenAttributeBlockIsDropped() {
        let out = body("<div hidden>Preview line \(padding)</div><p>Hello there</p>")
        #expect(!out.contains("Preview line"))
        #expect(out.contains("Hello there"))
    }

    @Test func hiddenStyleBlocksAreDropped() {
        let cases = [
            "<div style=\"max-height:0;overflow:hidden;\">SECRET\(padding)</div>",
            "<div style=\"max-height: 0px !important; overflow: hidden\">SECRET</div>",
            "<div style=\"height:0;overflow:hidden\">SECRET</div>",
            "<div style=\"display:none\">SECRET</div>",
            "<div style=\"visibility:hidden\">SECRET</div>",
            "<div style=\"mso-hide:all;display:none\">SECRET</div>",
            "<div style=\"mso-hide:all;max-height:0\">SECRET</div>",
            "<span style=\"opacity:0;font-size:0\">SECRET</span>",
        ]
        for html in cases {
            let out = body(html + "<p>Real words</p>")
            #expect(!out.contains("SECRET"), "\(html)")
            #expect(out.contains("Real words"))
        }
    }

    @Test func visibleContentWithLookalikeStylesIsKept() {
        let cases = [
            "<div style=\"mso-hide:all\">KEEP</div>",
            "<div style=\"max-height:0\">KEEP</div>",
            "<div style=\"opacity:0\">KEEP</div>",
            "<div class=\"m\" style=\"display:none\">KEEP</div>",
            "<div style=\"max-height:120px;overflow:hidden\">KEEP</div>",
        ]
        for html in cases { #expect(body(html).contains("KEEP"), "\(html)") }
    }

    @Test func hiddenBlocksAStylesheetCanRevealAreKept() {
        let gif = "data:image/gif;base64,R0lGODlhAQABAAAAACw="
        let swap = "<style>@media (prefers-color-scheme: dark) { .dark-logo { display:block !important; "
            + "max-height:none !important; overflow:visible !important } .light-logo { display:none !important } }</style>"
            + "<div class=\"light-logo\"><img src=\"\(gif)\" width=\"40\" height=\"40\" alt=\"Light logo\"></div>"
            + "<div class=\"dark-logo\" style=\"display:none;overflow:hidden;max-height:0px\">"
            + "<img src=\"\(gif)\" width=\"40\" height=\"40\" alt=\"Dark logo\"></div><p>Hello</p>"
        let out = body(swap)
        #expect(out.contains("Dark logo") && out.contains("Light logo") && out.contains("Hello"))
        let cases = [
            "<div class=\"mobile-only\" style=\"max-height:0;overflow:hidden\">KEEP</div>",
            "<div id=\"m1\" style=\"height:0;overflow:hidden\">KEEP</div>",
            "<span class=\"m\" style=\"opacity:0;font-size:0\">KEEP</span>",
            "<div class=\"m\" style=\"mso-hide:all;max-height:0\">KEEP</div>",
            "<div class=\"m\" style=\"visibility:hidden\">KEEP</div>",
        ]
        for html in cases { #expect(body(html + "<p>Real words</p>").contains("KEEP"), "\(html)") }
    }

    @Test func invisibleOnlyBlocksBeforeContentAreDropped() {
        let html = "<div class=\"pre\">\(padding)</div><p>&nbsp;</p><div>\u{200B}\u{FEFF}\u{00AD}</div>"
            + "<table><tr><td height=\"60\">&nbsp;</td></tr></table><p>Hello</p>"
        let out = body(html)
        #expect(!out.contains("\u{00A0}") && !out.contains("\u{200B}") && !out.contains("\u{034F}") && !out.contains("\u{200C}"))
        #expect(!out.contains("<table") && !out.contains("height"))
        #expect(out.contains("Hello"))
    }

    @Test func leadingLineBreaksAndNbspAreDropped() {
        let out = body("&nbsp;<br><br><br>\u{200B}<br><b>Hello</b>")
        #expect(!out.contains("<br"))
        #expect(!out.contains("\u{00A0}"))
        #expect(out.contains("Hello"))
    }

    @Test func runsOfBlankParagraphsCollapseToOne() {
        let out = body("<p>One</p><p>&nbsp;</p><p><o:p>&nbsp;</o:p></p><div><br></div><p>&nbsp;</p><p>Two</p>")
        #expect(out.components(separatedBy: "\u{00A0}").count - 1 == 1)
        #expect(out.contains("One") && out.contains("Two"))
    }

    @Test func lineBreakRunsKeepAtMostOneBlankLine() {
        let out = body("One<br><br><br><br><br>Two")
        #expect(out.components(separatedBy: "<br").count - 1 == 2)
        let separate = body("One<br> <br>\n<br><br>Two<br><br>Three")
        #expect(separate.components(separatedBy: "<br").count - 1 == 4)
    }

    @Test func spacerRowsCollapseAndAreCapped() {
        let rows = String(repeating: "<tr><td height=\"80\" style=\"line-height:80px\">&nbsp;</td></tr>", count: 4)
        let out = body("<table><tr><td>Top</td></tr>\(rows)<tr><td>Bottom</td></tr></table>")
        #expect(out.components(separatedBy: "<tr").count - 1 == 3, "one spacer between the two content rows")
        #expect(!out.contains("80"))
        #expect(out.contains("Top") && out.contains("Bottom"))
    }

    @Test func realVisibleContentIsUntouched() {
        let html = "<p style=\"background:#eee\">&nbsp;</p><hr><div style=\"border-top:1px solid #ccc\"></div>"
            + "<ul><li>Item</li></ul><img src=\"data:image/gif;base64,R0lGODlhAQABAAAAACw=\" width=\"40\" height=\"40\">"
            + "<p>Hello</p><p>World</p>"
        let on = body(html)
        let off = body(html, trim: false)
        for fragment in ["background", "<hr", "border-top", "<li", "<img", "Hello", "World"] {
            #expect(on.contains(fragment), "\(fragment)")
        }
        #expect(on == off, "nothing blank to remove")
    }

    @Test func leadingImageStopsTheLeadingRule() {
        let out = body("<div><img src=\"data:image/gif;base64,R0lGODlhAQABAAAAACw=\" width=\"40\" height=\"40\"></div><p>&nbsp;</p><p>Hi</p>")
        #expect(out.contains("<img"))
        #expect(out.contains("Hi"))
    }

    @Test func originalSpacingKeepsEverything() {
        let html = "<div hidden>H</div><p>&nbsp;</p><br><br><br><table><tr><td height=\"60\">&nbsp;</td></tr></table><p>Hello</p>"
        let off = body(html, trim: false)
        #expect(off.contains("height=\"60\""))
        #expect(off.contains("<br"))
        #expect(off.contains("\u{00A0}"))
    }

    @Test func composeModeIsUnchanged() {
        let out = HTMLSanitizer.sanitize("<p>&nbsp;</p><br><br><p>x</p>", options: SanitizerOptions(mode: .compose)).bodyHTML
        #expect(out.contains("\u{00A0}") && out.contains("<br"))
    }

    @Test func blockedImageCollapsesUnlessOriginalSpacing() {
        let html = "<img src=\"https://img.example/hero.png\" width=\"600\" height=\"400\"><p>Hi</p>"
        let sanitized = HTMLSanitizer.sanitize(html, options: SanitizerOptions())
        #expect(sanitized.bodyHTML == "<p>Hi</p>")
        #expect(sanitized.blockedRemote == 1)
        let theme = ThemeTokens.light
        let trimmed = ReaderDocument.make(sanitized, theme: theme, allowRemoteImages: false)
        #expect(!trimmed.contains("class=\"oh-body oh-original-spacing"))
        let kept = HTMLSanitizer.sanitize(html, options: SanitizerOptions(trimBlankSpace: false))
        #expect(kept.bodyHTML.contains("oh-blocked"))
        #expect(kept.bodyHTML.contains("height=\"400\""), "original spacing keeps the declared size")
        let original = ReaderDocument.make(kept, theme: theme, allowRemoteImages: false, keepOriginalSpacing: true)
        #expect(original.contains("class=\"oh-body oh-original-spacing"))
        let loaded = HTMLSanitizer.sanitize(html, options: SanitizerOptions(allowRemoteImages: true))
        #expect(!loaded.bodyHTML.contains("oh-blocked"))
        #expect(loaded.bodyHTML.contains("src=\"https://img.example/hero.png\""))
    }

    @Test func rendererHonoursTheContextFlagAndCacheKey() {
        let renderer = MessageRenderer()
        let content = MessageContent(html: "<div hidden>PRE</div><p>&nbsp;</p><p>Hello</p>", text: nil)
        guard case .html(let on) = renderer.render(content, context: RenderContext()),
              case .html(let off) = renderer.render(content, context: RenderContext(keepOriginalSpacing: true)) else {
            Issue.record("expected html"); return
        }
        #expect(!on.html.contains("PRE"))
        #expect(off.html.contains("PRE"))
        let key = MessageKey(account: AccountID(rawValue: 1), rowID: 7, gmailMessageID: GmailMessageID("m7"))
        #expect(renderer.cacheKey(for: key, context: RenderContext()) != renderer.cacheKey(for: key, context: RenderContext(keepOriginalSpacing: true)))
        #expect(renderer.cacheKey(for: key, context: RenderContext()).stableName != renderer.cacheKey(for: key, context: RenderContext(keepOriginalSpacing: true)).stableName)
    }
}
