import Foundation
import Testing
@testable import MailRender

@Test func quoteRunsAndDepth() {
    let doc = PlainTextDocument.parse("Sounds good.\r\n\r\nOn Tue, Sam wrote:\n> First\n> > Nested\n>Back\nAfter")
    #expect(doc.blocks == [
        .body("Sounds good.\n\nOn Tue, Sam wrote:"),
        .quote("First", depth: 1),
        .quote("Nested", depth: 2),
        .quote("Back", depth: 1),
        .body("After"),
    ])
}

@Test func signatureAfterDashDashSpace() {
    let doc = PlainTextDocument.parse("Body\n-- \nDana Ruiz\nFinance")
    #expect(doc.blocks == [.body("Body"), .signature("Dana Ruiz\nFinance")])
}

@Test func linksAreStrict() {
    let text = "See https://example.com/a and mailto:dana@example.com, not javascript:alert(1) or ftp://files.example/x"
    let links = PlainTextLinks.detect(in: text).map(\.url.absoluteString)
    #expect(links.contains("https://example.com/a"))
    #expect(links.contains("mailto:dana@example.com"))
    #expect(!links.contains { $0.hasPrefix("javascript") || $0.hasPrefix("ftp") })
}
