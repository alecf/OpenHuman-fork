import Foundation
import MailModel
import Testing
@testable import MailRender

private typealias Doc = RichTextDocument

private let sample = Doc(blocks: [
    .paragraph([.text("Hi ", []), .mention(Mention(name: "Dana", email: "dana@example.com")), .text(",", [])]),
    .paragraph([]),
    .paragraph([.text("Two  spaces, ", []), .text("bold", .bold), .text(" and ", []),
                .text("both", [.bold, .italic]), .lineBreak, .text("code", .code), .text(" ", []),
                .link(URL(string: "https://example.com/a?b=1&c=2")!, [.text("a link", .underline)]), .text(" end ", [])]),
    .list(ordered: false, items: [
        [.paragraph([.text("one", [])])],
        [.paragraph([.text("two", .strikethrough)]), .list(ordered: true, items: [[.paragraph([.text("nested", [])])], []])],
        [],
    ]),
    .quote([.paragraph([.text("quoted & <escaped>", [])])]),
    .image(InlineImageRef(contentID: "img-1@example.com", width: 320, height: 200, alt: "Chart")),
    .paragraph([.text(" leading and trailing ", [])]),
])

@Test func htmlIsMinimalSemanticMarkup() {
    let html = ComposeSerializer.html(sample, signature: nil, style: ComposeStyle(fontFamily: "Helvetica Neue", fontSize: 15))
    #expect(html.hasPrefix("<div dir=\"auto\" style=\"font-family:&#39;Helvetica Neue&#39;,-apple-system,Helvetica,Arial,sans-serif;font-size:15px\">"))
    #expect(html.contains("<p style=\"margin:0\">Hi <a href=\"mailto:dana@example.com\">@Dana</a>,</p>"))
    #expect(html.contains("<p style=\"margin:0\"><br></p>"))
    #expect(html.contains("Two &nbsp;spaces, <strong>bold</strong> and <strong><em>both</em></strong><br><code>code</code> "))
    #expect(html.contains("<a href=\"https://example.com/a?b=1&amp;c=2\"><u>a link</u></a>"))
    #expect(html.contains("<ul><li>one</li><li><s>two</s><ol><li>nested</li><li></li></ol></li><li></li></ul>")
            || html.contains("<ul><li>one</li><li><p style=\"margin:0\"><s>two</s></p><ol><li>nested</li><li></li></ol></li><li></li></ul>"))
    #expect(html.contains("quoted &amp; &lt;escaped&gt;"))
    #expect(html.contains("<img src=\"cid:img-1@example.com\" alt=\"Chart\" width=\"320\" height=\"200\">"))
    #expect(html.contains("<p style=\"margin:0\">&nbsp;leading and trailing&nbsp;</p>"))
    #expect(!html.contains("gmail_quote"), "the serializer never builds a quote")
}

@Test func htmlIsSafeOutput() throws {
    let hostile = Doc(blocks: [.paragraph([
        .link(URL(string: "javascript:alert(1)")!, [.text("x", [])]), .text("<script>alert(1)</script>", []),
        .link(URL(string: "https://ok.example")!, [.text("ok", [])]),
    ])])
    let html = ComposeSerializer.html(hostile, signature: SignatureHTML(html: "<b>Sam</b><script>x()</script><img src=\"https://logo.example/l.png\"><img src=\"cid:logo\">"),
                                      style: ComposeStyle(fontFamily: "x';}</style><script>", fontSize: 1e9))
    #expect(!html.contains("javascript:"))
    #expect(!html.contains("<script"))
    #expect(html.contains("&lt;script&gt;"))
    #expect(!html.contains("font-family"), "an invalid font name falls back to the default")
    #expect(html.contains("font-size:72px"))
    #expect(html.contains("<div class=\"gmail_signature\" data-smartmail=\"gmail_signature\"><b>Sam</b><img src=\"https://logo.example/l.png\"><img src=\"cid:logo\"></div>"))
}

@Test func emptyDocumentIsOneEmptyParagraph() {
    #expect(ComposeSerializer.html(Doc(), signature: nil) == "<div dir=\"auto\"><p style=\"margin:0\"><br></p></div>")
}

@Test func roundTripThroughImportHTML() {
    let html = ComposeSerializer.html(sample, signature: SignatureHTML(html: "Sam<br>Ops"))
    let back = ComposeSerializer.importHTML(html)
    #expect(back == sample.normalized, "\(back)")
}

@Test func roundTripRandomDocuments() {
    var generator = SplitMix64(seed: 0x5E7)
    let words = ["alpha", "beta", "gamma", "δέλτα", "שלום", "日本", "a&b", "<tag>", "x  y", " lead", "trail ", "émoji 🎉"]
    let marks: [Doc.Marks] = [[], .bold, .italic, [.bold, .italic], .underline, .strikethrough, .code]
    func inlines() -> [Doc.Inline] {
        (0..<(1 + Int(generator.next() % 5))).map { _ -> Doc.Inline in
            switch generator.next() % 6 {
            case 0: return .lineBreak
            case 1: return .link(URL(string: "https://e.example/\(generator.next() % 100)")!, [.text(words[Int(generator.next() % 12)], [])])
            default: return .text(words[Int(generator.next() % UInt64(words.count))], marks[Int(generator.next() % UInt64(marks.count))])
            }
        }
    }
    func blocks(_ depth: Int) -> [Doc.Block] {
        (0..<(1 + Int(generator.next() % 4))).map { _ -> Doc.Block in
            switch (generator.next() % 5, depth < 2) {
            case (0, true): return .list(ordered: generator.next() % 2 == 0, items: [[.paragraph(inlines())], blocks(depth + 1)])
            case (1, true): return .quote(blocks(depth + 1))
            case (2, _): return .image(InlineImageRef(contentID: "c\(generator.next() % 9)@x", width: 10, height: 10))
            default: return .paragraph(inlines())
            }
        }
    }
    for round in 0..<300 {
        let doc = Doc(blocks: blocks(0)).normalized
        let back = ComposeSerializer.importHTML(ComposeSerializer.html(doc, signature: nil))
        #expect(back == doc, "round \(round)")
        if back != doc { break }
    }
}

@Test func importStopsAtTheQuoteMarkerAndSkipsTheSignature() {
    let stored = "<div dir=\"auto\"><p style=\"margin:0\">New text</p></div><br><div class=\"gmail_signature\" data-smartmail=\"gmail_signature\">Sam</div>"
        + "<div class=\"gmail_quote\" data-oh-quote=\"1\"><div class=\"gmail_attr\">On Tue, Dana wrote:</div><blockquote>old</blockquote></div><p>after</p>"
    #expect(ComposeSerializer.importHTML(stored) == Doc(blocks: [.paragraph([.text("New text", [])])]))
}

@Test func importReadsOtherClientsHTML() {
    let html = """
        <div>Hello <b>there</b>,</div>
        <div><br></div>
        <div>Line one<br>Line two</div>
        <ul>
          <li>first</li>
          <li><i>second</i></li>
        </ul>
        <span style="color:red;font-family:Comic Sans">styled</span> <a href="javascript:alert(1)">bad</a> <a href="https://ok.example/">good</a>
        <img src="https://remote.example/x.png"><img src="cid:inline%40x" alt="i">
        """
    let doc = ComposeSerializer.importHTML(html)
    #expect(doc.blocks == [
        .paragraph([.text("Hello ", []), .text("there", .bold), .text(",", [])]),
        .paragraph([]),
        .paragraph([.text("Line one", []), .lineBreak, .text("Line two", [])]),
        .list(ordered: false, items: [[.paragraph([.text("first", [])])], [.paragraph([.text("second", .italic)])]]),
        .paragraph([.text("styled bad ", []), .link(URL(string: "https://ok.example/")!, [.text("good", [])])]),
        .image(InlineImageRef(contentID: "inline@x", alt: "i")),
    ])
}

@Test func importIsBoundedOnHostileInput() {
    let deep = String(repeating: "<b><div>", count: 5_000) + "x"
    let doc = ComposeSerializer.importHTML(deep)
    #expect(ComposeSerializer.plainText(doc, signature: nil).contains("x"))
}

@Test func plainTextAlternative() {
    let text = ComposeSerializer.plainText(sample, signature: SignatureHTML(html: "<b>Sam Reyes</b><br>Ops"))
    let expected = "Hi @Dana,\n\nTwo  spaces, bold and both\ncode a link (https://example.com/a?b=1&c=2) end\n"
        + "- one\n- two\n  1. nested\n  2.\n-\n> quoted & <escaped>\n[image: Chart]\n leading and trailing\n\n-- \nSam Reyes\nOps"
    #expect(text == expected, "\(text.debugDescription)")
}

@Test func plainTextUsesTheSignatureTextWhenGiven() {
    let text = ComposeSerializer.plainText(Doc(blocks: [.paragraph([.text("Hi", [])])]), signature: SignatureHTML(html: "<i>x</i>", text: "Sam"))
    #expect(text == "Hi\n\n-- \nSam")
}

@Test func documentsAreCodable() throws {
    let data = try JSONEncoder().encode(sample)
    #expect(try JSONDecoder().decode(Doc.self, from: data) == sample)
}

@Test func mentionFromParticipant() {
    let m = Mention(Participant(name: nil, email: "sam@example.com", isMe: false, hasUnread: false))
    #expect(m.label == "@sam@example.com")
}
