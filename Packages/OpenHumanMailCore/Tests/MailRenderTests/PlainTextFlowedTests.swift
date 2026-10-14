import Foundation
import MailModel
import Testing
@testable import MailRender

@Test func flowedLinesJoinAndStuffingIsRemoved() {
    let text = "This is a long \r\nparagraph that was \r\nwrapped.\r\n\r\n> Quoted soft \r\n> broken line.\r\n>> Deeper\r\n From the start\r\n-- \r\nSig \r\nline"
    let doc = PlainTextDocument.parse(text, format: .flowed(delSp: false))
    #expect(doc.blocks == [
        .body("This is a long paragraph that was wrapped."),
        .quote("Quoted soft broken line.", depth: 1),
        .quote("Deeper", depth: 2),
        .body("From the start"),
        .signature("Sig line"),
    ])
}

@Test func flowedDelSpRemovesTheSoftSpace() {
    let doc = PlainTextDocument.parse("日本語の長い \n文章です。", format: .flowed(delSp: true))
    #expect(doc.blocks == [.body("日本語の長い文章です。")])
}

@Test func flowedDoesNotJoinAcrossQuoteDepth() {
    let doc = PlainTextDocument.parse("> a \nb", format: .flowed(delSp: false))
    #expect(doc.blocks == [.quote("a ", depth: 1), .body("b")])
}

@Test func fixedTextKeepsLineBreaks() {
    #expect(PlainTextDocument.parse("a \nb").blocks == [.body("a \nb")])
}

@Test func signatureKeepsItsLinesVerbatim() {
    #expect(PlainTextDocument.parse("Hi\n-- \n> not a quote\nSam").blocks == [.body("Hi"), .signature("> not a quote\nSam")])
}

@Test func hugePlainTextIsCut() {
    let doc = PlainTextDocument.parse(String(repeating: "line\n", count: 100), maxBytes: 50)
    #expect(doc.blocks.map(\.text).joined().count <= 50)
}

@Test func plainTextWithNULAndControlsParses() {
    let doc = PlainTextDocument.parse("a\u{0}b\u{7}c\n> q\u{0}")
    #expect(doc.blocks.count == 2)
}

@Test func firstStrongCharacterSetsTheDirection() {
    #expect(TextDirection.firstStrong(in: "שלום Dana") == .rightToLeft)
    #expect(TextDirection.firstStrong(in: "123, مرحبا") == .rightToLeft)
    #expect(TextDirection.firstStrong(in: "Hello שלום") == .leftToRight)
    #expect(TextDirection.firstStrong(in: "\u{200F}x") == .rightToLeft)
    #expect(TextDirection.firstStrong(in: "123 !?") == nil)
}

@Test func extractorDropsQuotesAttributionAndSignature() {
    let plain = "Thanks, that works.\n\nOn Tue, Oct 7, Dana wrote:\n> Can you check the numbers?\n> -- \n-- \nSam"
    #expect(PlainTextExtractor.extract(MessageContent(html: nil, text: plain)) == "Thanks, that works.")
    let outlook = "Approved.\n\n-----Original Message-----\nFrom: Felix\nSent: Thursday\nSubject: Order\n\nPlease approve."
    #expect(PlainTextExtractor.extract(MessageContent(html: nil, text: outlook)) == "Approved.")
    let header = "Sure.\n\nFrom: Felix <f@example.com>\nSent: Thursday\nTo: me\nSubject: Order\n\nold"
    #expect(PlainTextExtractor.extract(MessageContent(html: nil, text: header)) == "Sure.")
}

@Test func extractorReadsHTMLWithoutHiddenContent() {
    let html = """
        <style>.x{}</style><script>ignore()</script><div>Hello <b>team</b>,</div><div><br></div><div>Two items:</div>
        <ul><li>first</li><li>second</li></ul><div class="gmail_signature">Sam</div>
        <div class="gmail_quote"><div class="gmail_attr">On Tue, Dana wrote:</div><blockquote>old text</blockquote></div>
        """
    #expect(PlainTextExtractor.extract(MessageContent(html: html, text: "fallback")) == "Hello team,\n\nTwo items:\n- first\n- second")
}

@Test func extractorLimitsLength() {
    let long = String(repeating: "word ", count: 10_000)
    let out = PlainTextExtractor.extract(MessageContent(html: nil, text: long), maxCharacters: 100)
    #expect(out.count <= 100 && out.hasSuffix("word"))
}

@Test func extractorOnEveryFixtureHasNoMarkup() {
    for fixture in EmailFixture.all {
        let text = PlainTextExtractor.extract(MessageContent(html: fixture.html, text: nil))
        #expect(!text.contains("<script") && !text.contains("alert(") && !text.contains("{"), "\(fixture.name): \(text.prefix(200))")
    }
}
