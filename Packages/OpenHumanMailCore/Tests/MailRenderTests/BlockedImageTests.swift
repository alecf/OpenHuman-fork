import Foundation
import Testing
@testable import MailRender

@Suite struct BlockedImageTests {
    static let newsletter = "<p>Spring catalogue</p>"
        + "<a href=\"https://shop.example/garden\"><img src=\"https://img.example/hero.jpg\" width=\"600\" height=\"320\" alt=\"Garden chairs\"></a>"
        + "<img src=\"https://img.example/divider.png\" width=\"600\" height=\"24\">"
        + "<img src=\"https://img.example/spacer.gif\" width=\"600\" height=\"40\" alt=\"\">"
        + "<img src=\"https://img.example/blank.gif\" alt=\" &nbsp;\t\">"
        + "<img src=\"https://img.example/mugs.jpg\" width=\"280\" height=\"200\" alt=\"Mugs &amp; plates\n <new>\">"
        + "<img src=\"https://img.example/open.gif\" width=\"1\" height=\"1\" alt=\"Open pixel\">"
        + "<img src=\"https://img.example/px.gif\" style=\"width:1px;height:1px\" alt=\"Style pixel\">"
        + "<img src=\"data:image/png;base64,iVBORw0KGgo=\" width=\"40\" height=\"40\" alt=\"Logo\">"
        + "<p>See you soon</p>"

    static let remoteSources = ["hero.jpg", "divider.png", "spacer.gif", "blank.gif", "mugs.jpg"]

    @Test func blockedImagesCollapseOrShowTheirAltText() {
        let s = HTMLSanitizer.sanitize(Self.newsletter, options: SanitizerOptions())
        #expect(s.bodyHTML == "<p>Spring catalogue</p>"
            + "<a href=\"https://shop.example/garden\" rel=\"noopener noreferrer\"><span class=\"oh-placeholder\">Garden chairs</span></a>"
            + "<span class=\"oh-placeholder\">Mugs &amp; plates &lt;new&gt;</span>"
            + "<img src=\"data:image/png;base64,iVBORw0KGgo=\" width=\"40\" height=\"40\" alt=\"Logo\">"
            + "<p>See you soon</p>")
        #expect(!s.bodyHTML.contains("img.example"))
        #expect(!s.bodyHTML.contains("oh-blocked"))
        #expect(!s.bodyHTML.contains("pixel"))
        #expect(s.blockedRemote == 5)
        #expect(s.trackers == 2)
        #expect(s.trackerReferences == 2)
        #expect(s.remoteReferences == 7)
    }

    @Test func loadingImagesRestoresEveryRealImage() {
        let s = HTMLSanitizer.sanitize(Self.newsletter, options: SanitizerOptions(allowRemoteImages: true))
        for name in Self.remoteSources {
            #expect(s.bodyHTML.contains("<img src=\"https://img.example/\(name)\""), "\(name)")
        }
        #expect(s.bodyHTML.contains("width=\"600\" height=\"320\" alt=\"Garden chairs\""))
        #expect(!s.bodyHTML.contains("oh-placeholder"))
        #expect(!s.bodyHTML.contains("open.gif") && !s.bodyHTML.contains("px.gif"))
        #expect(s.blockedRemote == 0)
        #expect(s.trackers == 2)
        #expect(s.remoteReferences == 7)
    }

    @Test func originalSpacingKeepsTheSizedPlaceholder() {
        let s = HTMLSanitizer.sanitize(Self.newsletter, options: SanitizerOptions(trimBlankSpace: false))
        #expect(s.bodyHTML.contains("<img class=\"oh-blocked\" width=\"600\" height=\"24\">"))
        #expect(s.bodyHTML.contains("<img class=\"oh-blocked\" width=\"600\" height=\"320\" alt=\"Garden chairs\">"))
        #expect(!s.bodyHTML.contains("oh-placeholder"))
        #expect(!s.bodyHTML.contains("img.example"))
        #expect(s.blockedRemote == 5)
        #expect(s.trackers == 2)
    }

    @Test func oversizedAltTextCollapsesLikeAMissingOne() {
        let limits = RenderLimits.default
        let alt = String(repeating: "a", count: limits.maxAttributeLength + 1)
        let s = HTMLSanitizer.sanitize("<img src=\"https://img.example/big.png\" alt=\"\(alt)\"><p>x</p>",
                                       options: SanitizerOptions())
        #expect(s.bodyHTML == "<p>x</p>")
        #expect(s.blockedRemote == 1)
    }

    @Test func blockedImagesBeforeTheFirstTextDoNotKeepLeadingSpace() {
        let s = HTMLSanitizer.sanitize("<img src=\"https://img.example/logo.png\" width=\"200\" height=\"80\"><p>&nbsp;</p><br><p>Hello</p>",
                                       options: SanitizerOptions())
        #expect(s.bodyHTML == "<p>Hello</p>")
    }
}
