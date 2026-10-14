import Foundation
import Testing
@testable import MailRender

@Suite struct PasteLinkTests {
    @Test func oneWebOrMailLinkIsALink() {
        #expect(ComposePaste.linkURL(fromPastedText: "https://example.com/a")?.absoluteString == "https://example.com/a")
        #expect(ComposePaste.linkURL(fromPastedText: "http://example.com")?.absoluteString == "http://example.com")
        #expect(ComposePaste.linkURL(fromPastedText: "  https://example.com/a?utm_source=x&id=7\r\n")?.absoluteString
                == "https://example.com/a?id=7", "trimmed, tracking parameters removed")
        #expect(ComposePaste.linkURL(fromPastedText: "HTTPS://example.com/b")?.host == "example.com")
        #expect(ComposePaste.linkURL(fromPastedText: "mailto:someone@example.org")?.absoluteString
                == "mailto:someone@example.org")
        #expect(ComposePaste.linkURL(fromPastedText: "https://example.com/\u{200B}x")?.absoluteString
                == "https://example.com/x", "invisible padding is not part of the link")
    }

    @Test func anythingElseIsAnOrdinaryPaste() {
        for text in ["", "   ", "plan", "example.com", "see https://example.com", "https://example.com and more",
                     "https://", "ftp://example.com/file", "javascript:alert(1)", "file:///tmp/x", "mailto:nobody",
                     "https://example.com\nhttps://example.org", "data:text/plain,hi"] {
            #expect(ComposePaste.linkURL(fromPastedText: text) == nil, "\(text)")
        }
    }
}
